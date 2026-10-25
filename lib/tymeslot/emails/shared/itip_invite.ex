defmodule Tymeslot.Emails.Shared.ITipInvite do
  @moduledoc """
  The opt-in switch that turns the booker-facing emails into real iTIP meeting
  requests, and the one place that decides whether an email can carry one.

  ## Why it is off by default

  A `METHOD:REQUEST` calendar part makes the recipient's server act on the
  message: Outlook shows Accept/Decline and writes the event, and servers that
  process iMIP (Zimbra, Nextcloud, iCloud) import the event and may notify the
  attendee themselves. Tymeslot's emails deliberately avoided that (issue #41),
  so the behaviour is opt-in: `EMAIL_ITIP_INVITES=true`.

  ## What it changes

  With the switch on, the booker and guest confirmation, reschedule and
  cancellation emails are sent as `multipart/alternative` with a
  `text/calendar; method=REQUEST` (or `method=CANCEL`) part, built by
  `Tymeslot.Mailer.ITipMessage`, instead of carrying the `.ics` as an
  attachment. Everything else — the organiser's copies, `.ics` downloads,
  calendar exports — is untouched.

  ## When it stays off even with the switch on

  - The configured adapter is not `Tymeslot.Mailer.SMTPAdapter`. The API
    adapters encode the message themselves and cannot send a pre-encoded body,
    so the email keeps its ordinary attachment rather than failing to send.
  - The email has no plain-text or no HTML body, which the alternative tree
    requires.
  - Encoding fails for any other reason. The failure is logged and the email
    is sent unchanged, with its `.ics` attachment, rather than not at all.

  `EMAIL_ITIP_INVITES` accepts `true` or `false` (case-insensitive). Any other
  value is logged as a warning and treated as off — a typo in an optional
  switch must never stop booking emails from going out.
  """

  alias Tymeslot.Mailer
  alias Tymeslot.Mailer.ITipMessage

  require Logger

  @env_var "EMAIL_ITIP_INVITES"
  @boolean_values %{"true" => true, "false" => false}
  @warned_table :tymeslot_itip_invite_warned

  @doc "Whether `#{@env_var}` asks for iTIP invitations. Off unless set to `true`."
  @spec enabled?() :: boolean()
  def enabled? do
    case System.get_env(@env_var) do
      nil ->
        false

      value ->
        case Map.fetch(@boolean_values, value |> String.trim() |> String.downcase()) do
          {:ok, enabled} ->
            enabled

          :error ->
            warn_once(value)
            false
        end
    end
  end

  # A typo in an optional switch must not stop every booking email from
  # going out, so it is reported and treated as off. Logged once per value so
  # a busy instance does not fill its log with the same line per email.
  defp warn_once(value) do
    unless :ets.member(table(), value) do
      :ets.insert(table(), {value})

      Logger.warning(
        "Ignoring #{@env_var}: expected true or false, got #{inspect(value)}. " <>
          "Sending the usual .ics attachment instead.",
        setting: @env_var
      )
    end
  end

  defp table do
    case :ets.whereis(@warned_table) do
      :undefined ->
        :ets.new(@warned_table, [:named_table, :public, :set, read_concurrency: true])

      _tid ->
        @warned_table
    end
  end

  @doc """
  Whether this email can go out as an iTIP request on the configured adapter.

  Both bodies must be present: the alternative tree needs the plain-text part,
  and the HTML part is what the recipient actually reads.
  """
  @spec deliverable?(Swoosh.Email.t()) :: boolean()
  def deliverable?(%Swoosh.Email{text_body: text_body, html_body: html_body})
      when is_binary(text_body) and is_binary(html_body) do
    text_body != "" and html_body != "" and enabled?() and smtp_adapter?()
  end

  def deliverable?(%Swoosh.Email{}), do: false

  @doc """
  Encodes `email` with `calendar` as its third alternative part and returns it
  ready for delivery, or returns it unchanged when it cannot carry one.

  `method` is `"REQUEST"` or `"CANCEL"`. The logo is taken from the email's
  inline attachments, so the HTML keeps rendering with its header image.

  An email that cannot be encoded is still an email that must go out, so any
  failure here is logged and the email is returned untouched: it then takes
  the ordinary Swoosh path with its `.ics` attachment.
  """
  @spec put_itip_body(Swoosh.Email.t(), String.t(), String.t()) :: Swoosh.Email.t()
  def put_itip_body(%Swoosh.Email{} = email, calendar, method)
      when method in ["REQUEST", "CANCEL"] do
    if deliverable?(email) do
      encode_or_keep(email, calendar, method)
    else
      email
    end
  end

  defp encode_or_keep(email, calendar, method) do
    email
    |> ITipMessage.put_message_id(new_message_id())
    |> ITipMessage.encode(%{
      text: email.text_body,
      html: email.html_body,
      calendar: calendar,
      calendar_method: method,
      logo: logo(email)
    })
    |> then(&ITipMessage.put_encoded_body(email, &1))
  rescue
    error ->
      Logger.warning(
        "Could not encode the iTIP body for #{inspect(email.subject)}; " <>
          "sending the usual .ics attachment instead: " <>
          Exception.format(:error, error, __STACKTRACE__),
        setting: @env_var
      )

      email
  end

  defp new_message_id do
    random = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    "#{System.system_time(:microsecond)}.#{random}@#{message_id_domain()}"
  end

  defp message_id_domain do
    case Application.get_env(:tymeslot, :email)[:from_email] do
      address when is_binary(address) ->
        case String.split(address, "@") do
          [_local, domain] when domain != "" -> domain
          _other -> "tymeslot.local"
        end

      _other ->
        "tymeslot.local"
    end
  end

  defp logo(%Swoosh.Email{attachments: attachments}) do
    Enum.find_value(attachments, fn attachment ->
      if attachment.type == :inline and attachment.cid do
        %{data: attachment.data, cid: attachment.cid}
      end
    end)
  end

  defp smtp_adapter? do
    config = Application.get_env(:tymeslot, Mailer, [])
    Keyword.get(config, :adapter) == Tymeslot.Mailer.SMTPAdapter
  end
end
