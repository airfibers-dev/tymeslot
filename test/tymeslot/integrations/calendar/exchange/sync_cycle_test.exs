defmodule Tymeslot.Integrations.Calendar.Exchange.SyncCycleTest do
  @moduledoc """
  One Exchange sync cycle, run without Oban: the two reads, the order they
  run in, the bookkeeping of a completed cycle, and the outcome a failed one
  hands its caller with nothing recorded against the integration.
  """

  use Tymeslot.DataCase, async: false

  import ExUnit.CaptureLog
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.ExchangeSyncStubs
  import Tymeslot.Factory

  @moduletag :calendar
  @moduletag :integrations

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.ExchangeCase
  alias Tymeslot.ExchangeFixtures
  alias Tymeslot.Integrations.Calendar.CalendarEventQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Exchange.SyncCycle
  alias Tymeslot.Security.Encryption

  @base_url "https://cycle.example.com/EWS/Exchange.asmx"

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    ExchangeCase.reset_breaker(@base_url)

    inserted =
      insert(:calendar_integration,
        provider: "exchange",
        base_url: @base_url,
        username_encrypted: Encryption.encrypt("user@example.com"),
        password_encrypted: Encryption.encrypt("secret"),
        provider_account_email: "user@example.com",
        calendar_list: [],
        sync_error: nil,
        needs_reauth: false
      )

    {:ok, integration} = CalendarIntegrationQueries.get(inserted.id)
    %{integration: integration}
  end

  defp rows(integration, role) do
    CalendarEventQueries.any_in_range?(integration.id, role, window_start(), window_end())
  end

  test "a completed cycle writes both halves and stamps a full read", %{integration: integration} do
    stub_full_sync()

    assert :ok = SyncCycle.run(integration)

    assert rows(integration, "busy_only")
    assert rows(integration, "display_only")

    assert {:ok, %{last_external_sync_at: %DateTime{}, last_full_sync_at: %DateTime{}}} =
             CalendarIntegrationQueries.get(integration.id)
  end

  describe "the sync window" do
    test "reads 30 days back and 180 forward, narrower than the shared window" do
      now = ~U[2026-10-09 12:00:00Z]
      {from, to} = SyncCycle.window(now)

      assert DateTime.diff(now, from, :day) == 30
      assert DateTime.diff(to, now, :day) == 180

      # The shared window is what fills `FindItem`'s 1000-entry cap with
      # history, so the Exchange one must stay inside it.
      {shared_from, shared_to} = Tymeslot.Integrations.Calendar.Sync.window(now)
      assert DateTime.compare(from, shared_from) == :gt
      assert DateTime.compare(to, shared_to) == :lt
    end

    test "is the window the cycle actually reads", %{integration: integration} do
      stub_full_sync()

      assert :ok = SyncCycle.run(integration)

      {from, to} = SyncCycle.window()
      find_item = Enum.find(sent_requests(), &(&1 =~ "<m:FindItem"))

      assert find_item =~ ~s(StartDate="#{ews_time(from)}")
      assert find_item =~ ~s(EndDate="#{ews_time(to)}")
    end
  end

  # `FindItem`'s `CalendarView` bounds are UTC ISO-8601, truncated to the
  # second (see `Exchange.Requests.find_item/3`).
  defp ews_time(datetime),
    do: datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  describe "a refused availability read" do
    setup do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        send(test_pid, {:ews_request, body})
        Conn.resp(conn, 401, "Unauthorized")
      end)

      :ok
    end

    test "is the cycle's outcome, with nothing recorded", %{integration: integration} do
      assert {:error, :unauthorized} = SyncCycle.run(integration)

      assert {:ok, %{needs_reauth: false, sync_error: nil, last_external_sync_at: nil}} =
               CalendarIntegrationQueries.get(integration.id)
    end

    test "stops the cycle before the item read", %{integration: integration} do
      assert {:error, :unauthorized} = SyncCycle.run(integration)

      requests = sent_requests()
      assert requests != []
      assert Enum.all?(requests, &(&1 =~ "<m:GetUserAvailabilityRequest"))
    end
  end

  test "an empty availability read over cached busy time is refused", %{integration: integration} do
    stub_full_sync()
    assert :ok = SyncCycle.run(integration)

    stub_full_sync(intervals: [])

    assert {:error, {:empty_feed_with_populated_cache, "busy_only"}} =
             SyncCycle.run(integration)

    assert rows(integration, "busy_only")
  end

  # The calendar that silently empties: a server answering bare ids would have
  # every item rejected by the normaliser, and a full read of nothing would
  # replace the grid's rows.
  test "items answered without their properties keep the cached grid", %{
    integration: integration
  } do
    stub_full_sync()
    assert :ok = SyncCycle.run(integration)
    assert rows(integration, "display_only")

    stub_full_sync(get_item: ExchangeFixtures.get_item_response(id_only: true))

    assert {:error, :item_properties_missing} = SyncCycle.run(integration)
    assert rows(integration, "display_only")
  end

  describe "one item answered without its properties" do
    setup :capture_admin_alerts

    test "is skipped and reported, and the rest of the read is cached", %{
      integration: integration
    } do
      stub_full_sync(
        find_item: ExchangeFixtures.find_item_response([{"item-1", "ck-1"}, {"item-2", "ck-2"}]),
        get_item:
          ExchangeFixtures.get_item_batch_response([
            {:ok, id: "item-1", uid: "uid-1"},
            {:ok, id: "item-2", id_only: true}
          ])
      )

      capture_log(fn -> assert :ok = run(integration) end)

      assert Enum.map(grid_rows(integration), & &1.provider_event_id) == ["item-1"]

      assert_received {:send_alert, :invalid_calendar_event, %{count: 1, provider: :exchange}}
    end
  end
end
