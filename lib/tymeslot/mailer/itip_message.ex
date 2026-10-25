defmodule Tymeslot.Mailer.ITipMessage do
  @moduledoc """
  Builds the MIME body of an email that carries an iTIP invitation, in the
  shape Outlook reads as a meeting request.

  Swoosh's SMTP encoder cannot produce it: `Swoosh.Adapters.SMTP.Helpers`
  builds `multipart/alternative` only when there are no attachments, and any
  attachment — including the inline logo every Tymeslot email carries — turns
  the message into `multipart/mixed` with the calendar file as a
  `Content-Disposition: attachment` part. Outlook shows that as a paperclip,
  not as Accept/Decline.

  The tree built here is the one an Exchange-sent invite has:

      multipart/alternative
        text/plain
        multipart/related
          text/html
          image/png  (inline, Content-ID)
        text/calendar; charset="utf-8"; method=REQUEST

  The calendar part is base64 and carries no `Content-Disposition` and no
  filename: it is an alternative rendering of the message, not a file.

  `encode/1` returns the complete message — headers included — so the caller
  delivers it through `Tymeslot.Mailer.SMTPAdapter`'s pre-encoded path, which
  keeps that adapter's session and timeout handling and sends these bytes
  instead of encoding the `Swoosh.Email` itself.

  Only the SMTP adapter can send a pre-encoded body. On any other adapter the
  caller must fall back to the ordinary attachment, which is what
  `Tymeslot.Emails.Shared.ITipInvite` decides.
  """

  @crlf "\r\n"
  @encoded_body_key :tymeslot_encoded_body
  @message_id_key :tymeslot_message_id
  @text_content_type ~s(text/plain; charset="utf-8")
  @html_content_type ~s(text/html; charset="utf-8")
  @logo_content_type "image/png"

  @typedoc """
  The parts of the message this module writes itself. `calendar_method` is
  `"REQUEST"` or `"CANCEL"` and becomes the `method=` parameter of the calendar
  part, which is what tells Outlook which controls to show.
  """
  @type parts :: %{
          text: String.t(),
          html: String.t(),
          calendar: String.t(),
          calendar_method: String.t(),
          logo: %{data: binary(), cid: String.t()} | nil
        }

  @doc """
  Encodes the whole message: the headers of `email`, then the tree above.

  `parts.logo` is optional; without it the HTML is a plain sibling of the text
  part and the tree is `multipart/alternative` with two children.
  """
  @spec encode(Swoosh.Email.t(), parts()) :: binary()
  def encode(%Swoosh.Email{} = email, parts) do
    boundary = boundary()
    related_boundary = boundary()

    IO.iodata_to_binary([
      headers(email),
      "MIME-Version: 1.0",
      @crlf,
      "Content-Type: multipart/alternative; boundary=\"",
      boundary,
      "\"",
      @crlf,
      @crlf,
      "--",
      boundary,
      @crlf,
      text_part(parts.text),
      "--",
      boundary,
      @crlf,
      html_part(parts, related_boundary),
      "--",
      boundary,
      @crlf,
      calendar_part(parts.calendar, parts.calendar_method),
      "--",
      boundary,
      "--",
      @crlf
    ])
  end

  @doc """
  Stashes an encoded body on the email for `Tymeslot.Mailer.SMTPAdapter` to
  send instead of encoding the email itself.
  """
  @spec put_encoded_body(Swoosh.Email.t(), binary()) :: Swoosh.Email.t()
  def put_encoded_body(%Swoosh.Email{} = email, encoded) when is_binary(encoded) do
    Swoosh.Email.put_private(email, @encoded_body_key, encoded)
  end

  @doc "The body stashed by `put_encoded_body/2`, or `nil`."
  @spec encoded_body(Swoosh.Email.t()) :: binary() | nil
  def encoded_body(%Swoosh.Email{private: private}) when is_map(private),
    do: Map.get(private, @encoded_body_key)

  def encoded_body(_email), do: nil

  @doc """
  Stashes the `Message-ID` to write, so a retry of the same email carries the
  same one instead of looking like a second message to the recipient.
  """
  @spec put_message_id(Swoosh.Email.t(), String.t()) :: Swoosh.Email.t()
  def put_message_id(%Swoosh.Email{} = email, id) when is_binary(id) do
    Swoosh.Email.put_private(email, @message_id_key, id)
  end

  @doc """
  A MIME boundary that cannot occur in the content it delimits: the encoder
  writes random bytes, so no part can contain the delimiter by accident.
  """
  @spec boundary() :: String.t()
  def boundary do
    "----=_Tymeslot_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  defp headers(%Swoosh.Email{} = email) do
    [
      address_header("From", [email.from]),
      address_header("Reply-To", List.wrap(email.reply_to)),
      address_header("To", email.to),
      address_header("Cc", email.cc),
      "Message-ID: ",
      message_id(email),
      @crlf,
      "Subject: ",
      encode_header_text(email.subject || ""),
      @crlf,
      "Date: ",
      rfc5322_date(),
      @crlf
    ]
  end

  # Bcc is deliberately absent: it is an envelope recipient, not a header. The
  # SMTP session takes To+Cc+Bcc from the email struct itself, so a blind
  # recipient still receives the message without being named in it.
  defp message_id(%Swoosh.Email{private: private}) do
    case Map.get(private || %{}, @message_id_key) do
      id when is_binary(id) -> "<#{id}>"
      _other -> "<#{unique_id()}@#{message_id_domain()}>"
    end
  end

  defp unique_id do
    random = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    "#{System.system_time(:microsecond)}.#{random}"
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

  # An empty list writes nothing, so a message without Cc has no Cc header.
  defp address_header(_name, []), do: []

  defp address_header(name, addresses) do
    [
      name,
      ": ",
      addresses |> Enum.map(&mailbox/1) |> Enum.join(", "),
      @crlf
    ]
  end

  defp mailbox({name, address}) when is_binary(name) and name != "" do
    ~s("#{encode_header_text(name)}" <#{address}>)
  end

  defp mailbox({_name, address}), do: "<#{address}>"
  defp mailbox(address) when is_binary(address), do: "<#{address}>"

  # RFC 2047 encoded-word. The subject is the only header a user can write
  # freely, and it is already stripped of control characters by
  # `Tymeslot.Emails.Delivery`; this keeps non-ASCII subjects intact.
  defp encode_header_text(text) do
    if String.printable?(text) and ascii?(text) do
      text
    else
      "=?UTF-8?B?" <> Base.encode64(text) <> "?="
    end
  end

  defp ascii?(text), do: text |> String.to_charlist() |> Enum.all?(&(&1 < 128))

  defp rfc5322_date do
    now = DateTime.utc_now()

    Calendar.strftime(now, "%a, %d %b %Y %H:%M:%S +0000")
  end

  defp text_part(text) do
    [
      "Content-Type: ",
      @text_content_type,
      @crlf,
      "Content-Transfer-Encoding: base64",
      @crlf,
      @crlf,
      base64(text),
      @crlf
    ]
  end

  defp html_part(%{logo: nil} = parts, _related_boundary) do
    [
      "Content-Type: ",
      @html_content_type,
      @crlf,
      "Content-Transfer-Encoding: base64",
      @crlf,
      @crlf,
      base64(parts.html),
      @crlf
    ]
  end

  defp html_part(%{logo: logo} = parts, related_boundary) do
    [
      "Content-Type: multipart/related; boundary=\"",
      related_boundary,
      "\"",
      @crlf,
      @crlf,
      "--",
      related_boundary,
      @crlf,
      "Content-Type: ",
      @html_content_type,
      @crlf,
      "Content-Transfer-Encoding: base64",
      @crlf,
      @crlf,
      base64(parts.html),
      @crlf,
      "--",
      related_boundary,
      @crlf,
      "Content-Type: ",
      @logo_content_type,
      @crlf,
      "Content-Transfer-Encoding: base64",
      @crlf,
      "Content-ID: <",
      logo.cid,
      ">",
      @crlf,
      "Content-Disposition: inline; filename=\"",
      logo.cid,
      "\"",
      @crlf,
      @crlf,
      base64(logo.data),
      @crlf,
      "--",
      related_boundary,
      "--",
      @crlf
    ]
  end

  defp calendar_part(calendar, method) do
    [
      "Content-Type: text/calendar; charset=\"utf-8\"; method=",
      method,
      @crlf,
      "Content-Transfer-Encoding: base64",
      @crlf,
      @crlf,
      base64(calendar),
      @crlf
    ]
  end

  # Wrapped at 76 columns, CRLF-separated, as base64 in MIME is (RFC 2045
  # §6.8). The ICS itself is already CRLF-folded by `ContentLines.join/1`.
  defp base64(data) do
    data
    |> Base.encode64()
    |> String.codepoints()
    |> Enum.chunk_every(76)
    |> Enum.map_join(@crlf, &Enum.join/1)
  end
end
