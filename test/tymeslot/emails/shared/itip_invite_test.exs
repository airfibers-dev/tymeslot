defmodule Tymeslot.Emails.Shared.ITipInviteTest do
  @moduledoc """
  The `EMAIL_ITIP_INVITES` switch and what it does to a built email: off by
  default, only on the SMTP adapter, and never at the cost of a missing
  plain-text body.
  """

  use ExUnit.Case, async: false
  @moduletag :emails

  import ExUnit.CaptureLog
  import Swoosh.Email

  alias Tymeslot.Emails.Shared.ITipInvite
  alias Tymeslot.Mailer.ITipMessage

  @calendar "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nEND:VCALENDAR\r\n"

  setup do
    original_mailer = Application.get_env(:tymeslot, Tymeslot.Mailer)
    original_env = System.get_env("EMAIL_ITIP_INVITES")

    on_exit(fn ->
      Application.put_env(:tymeslot, Tymeslot.Mailer, original_mailer)

      if original_env,
        do: System.put_env("EMAIL_ITIP_INVITES", original_env),
        else: System.delete_env("EMAIL_ITIP_INVITES")
    end)

    :ok
  end

  defp use_smtp_adapter do
    Application.put_env(:tymeslot, Tymeslot.Mailer, adapter: Tymeslot.Mailer.SMTPAdapter)
  end

  defp build_email do
    new()
    |> from({"Tymeslot", "no-reply@tymeslot.example.com"})
    |> to({"Jane Attendee", "jane@example.com"})
    |> subject("Appointment Confirmed")
    |> text_body("Plain text body")
    |> html_body("<html><body>Body</body></html>")
  end

  describe "enabled?/0" do
    test "is off when the variable is unset" do
      System.delete_env("EMAIL_ITIP_INVITES")

      refute ITipInvite.enabled?()
    end

    test "is off for false and on for true, case-insensitively" do
      System.put_env("EMAIL_ITIP_INVITES", "false")
      refute ITipInvite.enabled?()

      System.put_env("EMAIL_ITIP_INVITES", "TRUE")
      assert ITipInvite.enabled?()
    end

    # A typo in an optional switch must never stop booking emails from going
    # out: it is reported once and treated as off.
    test "an invalid value logs a warning and behaves as off" do
      System.put_env("EMAIL_ITIP_INVITES", "yes")
      use_smtp_adapter()

      log =
        capture_log(fn ->
          refute ITipInvite.enabled?()

          email = ITipInvite.put_itip_body(build_email(), @calendar, "REQUEST", %{})
          assert ITipMessage.encoded_body(email) == nil
        end)

      assert log =~ "Ignoring EMAIL_ITIP_INVITES"
      assert log =~ "\"yes\""
    end
  end

  describe "put_itip_body/4" do
    # A meeting the host manages (confirmed from a poll) has no booker: the
    # person in its attendee fields is a guest, and there is no booker's
    # calendar entry for a request to create or a cancel to withdraw. Its
    # guests keep the ordinary .ics attachment.
    test "leaves a host-managed meeting's email alone" do
      System.put_env("EMAIL_ITIP_INVITES", "true")
      use_smtp_adapter()

      email =
        ITipInvite.put_itip_body(
          build_email(),
          @calendar,
          "REQUEST",
          %{host_managed: true}
        )

      assert ITipMessage.encoded_body(email) == nil
    end

    test "leaves the email alone when the switch is off" do
      System.delete_env("EMAIL_ITIP_INVITES")
      use_smtp_adapter()

      email = ITipInvite.put_itip_body(build_email(), @calendar, "REQUEST", %{})

      assert ITipMessage.encoded_body(email) == nil
    end

    test "leaves the email alone on an adapter that cannot send a pre-encoded body" do
      System.put_env("EMAIL_ITIP_INVITES", "true")
      Application.put_env(:tymeslot, Tymeslot.Mailer, adapter: Swoosh.Adapters.Test)

      email = ITipInvite.put_itip_body(build_email(), @calendar, "REQUEST", %{})

      assert ITipMessage.encoded_body(email) == nil
    end

    test "leaves an email without a text body alone" do
      System.put_env("EMAIL_ITIP_INVITES", "true")
      use_smtp_adapter()

      email = ITipInvite.put_itip_body(%{build_email() | text_body: nil}, @calendar, "REQUEST", %{})

      assert ITipMessage.encoded_body(email) == nil
    end

    test "leaves an email without an html body alone" do
      System.put_env("EMAIL_ITIP_INVITES", "true")
      use_smtp_adapter()

      email = ITipInvite.put_itip_body(%{build_email() | html_body: nil}, @calendar, "REQUEST", %{})

      assert ITipMessage.encoded_body(email) == nil
    end

    # An email that cannot be encoded must still be sent: the failure is
    # logged and the email comes back exactly as it went in, so it takes the
    # ordinary Swoosh path with its .ics attachment.
    test "a failing encoder logs and returns the email unchanged" do
      System.put_env("EMAIL_ITIP_INVITES", "true")
      use_smtp_adapter()

      original = build_email()

      log =
        capture_log(fn ->
          email = ITipInvite.put_itip_body(original, nil, "REQUEST", %{})

          assert email == original
          assert ITipMessage.encoded_body(email) == nil
        end)

      assert log =~ "Could not encode the iTIP body"
      assert log =~ "Appointment Confirmed"
    end

    test "encodes the tree when the switch is on and the adapter is SMTP" do
      System.put_env("EMAIL_ITIP_INVITES", "true")
      use_smtp_adapter()

      email = ITipInvite.put_itip_body(build_email(), @calendar, "REQUEST", %{})
      encoded = ITipMessage.encoded_body(email)

      assert encoded =~ "Content-Type: multipart/alternative; boundary="
      assert encoded =~ "Content-Type: text/calendar; charset=\"utf-8\"; method=REQUEST"
      assert encoded =~ "Content-Type: text/plain; charset=\"utf-8\""
    end

    test "a cancellation is encoded as method=CANCEL" do
      System.put_env("EMAIL_ITIP_INVITES", "true")
      use_smtp_adapter()

      email = ITipInvite.put_itip_body(build_email(), @calendar, "CANCEL", %{})

      assert ITipMessage.encoded_body(email) =~ "method=CANCEL"
    end
  end
end
