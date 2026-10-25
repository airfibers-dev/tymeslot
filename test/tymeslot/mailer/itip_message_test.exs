defmodule Tymeslot.Mailer.ITipMessageTest do
  @moduledoc """
  The encoded message `Tymeslot.Mailer.ITipMessage` builds: the tree Outlook
  reads as a meeting request, and the headers it needs to deliver it.

  These assert on the bytes that reach the SMTP adapter, not on the
  `Swoosh.Email`, because the whole point of the module is that Swoosh's own
  encoder cannot produce this shape.
  """

  use ExUnit.Case, async: true
  @moduletag :emails

  import Swoosh.Email

  alias Tymeslot.Mailer.ITipMessage

  @logo %{data: <<137, 80, 78, 71, 13, 10, 26, 10>>, cid: "tymeslot-logo.png"}

  @calendar "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nEND:VCALENDAR\r\n"

  defp build_email do
    new()
    |> from({"Tymeslot", "no-reply@tymeslot.example.com"})
    |> to({"Jane Attendee", "jane@example.com"})
    |> reply_to({"John Organizer", "organizer@example.com"})
    |> subject("Appointment Confirmed - 15 January 2026")
    |> text_body("Plain text body")
    |> html_body("<html><body><img src=\"cid:tymeslot-logo.png\"></body></html>")
  end

  defp encode(email, overrides \\ %{}) do
    ITipMessage.encode(
      email,
      Map.merge(
        %{
          text: email.text_body,
          html: email.html_body,
          calendar: @calendar,
          calendar_method: "REQUEST",
          logo: @logo
        },
        overrides
      )
    )
  end

  defp boundary(message) do
    [_, boundary] =
      Regex.run(~r/Content-Type: multipart\/alternative; boundary="([^"]+)"/, message)

    boundary
  end

  describe "the MIME tree" do
    test "is multipart/alternative with text, related html and the calendar as siblings" do
      message = encode(build_email())
      boundary = boundary(message)

      assert message =~ "MIME-Version: 1.0\r\n"
      assert message =~ "Content-Type: multipart/alternative; boundary=\"#{boundary}\"\r\n"

      # Three top-level children, in the order the reference invite has them.
      children =
        message
        |> String.split("--#{boundary}\r\n")
        |> Enum.drop(1)
        |> Enum.take(3)

      assert [text, related, calendar] = children
      assert text =~ "Content-Type: text/plain; charset=\"utf-8\""
      assert related =~ "Content-Type: multipart/related; boundary="
      assert calendar =~ "Content-Type: text/calendar; charset=\"utf-8\"; method=REQUEST"
      assert message =~ "--#{boundary}--\r\n"
    end

    test "the html and the inline logo sit inside multipart/related" do
      message = encode(build_email())

      assert message =~ "Content-Type: multipart/related; boundary="
      assert message =~ "Content-Type: text/html; charset=\"utf-8\""
      assert message =~ "Content-Type: image/png"
      assert message =~ "Content-ID: <tymeslot-logo.png>"
      assert message =~ "Content-Disposition: inline; filename=\"tymeslot-logo.png\""
    end

    test "the calendar part is base64 with no disposition and no filename" do
      message = encode(build_email())

      [calendar_part] =
        Regex.run(
          ~r/Content-Type: text\/calendar; charset="utf-8"; method=REQUEST\r\n.*?(?=--)/s,
          message
        )

      assert calendar_part =~ "Content-Transfer-Encoding: base64"
      refute calendar_part =~ "Content-Disposition"
      refute calendar_part =~ "filename"

      encoded =
        calendar_part
        |> String.split("\r\n\r\n", parts: 2)
        |> List.last()
        |> String.trim()

      assert Base.decode64!(encoded) == @calendar
    end

    test "a cancellation is method=CANCEL on the same tree" do
      message = encode(build_email(), %{calendar_method: "CANCEL"})

      assert message =~ "Content-Type: text/calendar; charset=\"utf-8\"; method=CANCEL"
    end

    test "without a logo the html is a plain sibling of the text part" do
      message = encode(build_email(), %{logo: nil})

      refute message =~ "multipart/related"
      assert message =~ "Content-Type: text/html; charset=\"utf-8\""
    end

    test "base64 lines are wrapped at 76 columns" do
      message = encode(build_email(), %{text: String.duplicate("a", 500)})

      [text_part] =
        Regex.run(~r/Content-Type: text\/plain; charset="utf-8"\r\n.*?(?=--)/s, message)

      lines =
        text_part
        |> String.split("\r\n\r\n", parts: 2)
        |> List.last()
        |> String.split("\r\n", trim: true)

      assert Enum.all?(lines, &(String.length(&1) <= 76))
    end
  end

  describe "the headers" do
    test "carry the envelope the SMTP session does not add" do
      message = encode(build_email())

      assert message =~ "From: \"Tymeslot\" <no-reply@tymeslot.example.com>\r\n"
      assert message =~ "To: \"Jane Attendee\" <jane@example.com>\r\n"
      assert message =~ "Reply-To: \"John Organizer\" <organizer@example.com>\r\n"
      assert message =~ "Subject: Appointment Confirmed - 15 January 2026\r\n"
      assert message =~ "Date: "
      assert message =~ "MIME-Version: 1.0\r\n"
    end

    test "carry a Message-ID, and the one stashed on the email when there is one" do
      message = encode(build_email())

      assert message =~ ~r/Message-ID: <[^>\s]+@[^>\s]+>\r\n/

      stashed =
        build_email()
        |> ITipMessage.put_message_id("fixed-id@tymeslot.example.com")
        |> encode()

      assert stashed =~ "Message-ID: <fixed-id@tymeslot.example.com>\r\n"
    end

    # Bcc is an envelope recipient, not a header: the SMTP session takes it
    # from the email struct, and naming it here would disclose it to everyone.
    test "never name a Bcc recipient" do
      email = %{build_email() | bcc: [{"Blind", "blind@example.com"}]}
      message = encode(email)

      refute message =~ "Bcc:"
      refute message =~ "blind@example.com"
    end

    test "a non-ASCII subject is an RFC 2047 encoded word" do
      email = %{build_email() | subject: "Bestätigung"}
      message = encode(email)

      assert message =~ "Subject: =?UTF-8?B?"
      refute message =~ "Bestätigung"
    end

    test "no Cc header when there is no Cc" do
      refute encode(build_email()) =~ "Cc:"
    end
  end

  describe "line endings and transfer encoding" do
    test "every line ends CRLF and no bare LF or CR survives" do
      message = encode(build_email(), %{text: "one\ntwo\r\nthree"})

      refute Regex.match?(~r/(?<!\r)\n/, message)
      refute Regex.match?(~r/\r(?!\n)/, message)
    end

    test "text parts are base64, so a body with 8-bit or very long lines is safe" do
      message = encode(build_email(), %{text: String.duplicate("Grüße ", 200)})

      assert message =~ "Content-Transfer-Encoding: base64"
      refute message =~ "Grüße"
    end

    test "the alternative and related boundaries differ" do
      message = encode(build_email())

      [_, alternative] =
        Regex.run(~r/Content-Type: multipart\/alternative; boundary="([^"]+)"/, message)

      [_, related] = Regex.run(~r/Content-Type: multipart\/related; boundary="([^"]+)"/, message)

      assert alternative != related
      assert message =~ "--#{related}--\r\n"
      assert message =~ "--#{alternative}--\r\n"
    end
  end

  describe "put_encoded_body/2 and encoded_body/1" do
    test "round-trips the body on the email's private map" do
      email = ITipMessage.put_encoded_body(build_email(), "encoded")

      assert ITipMessage.encoded_body(email) == "encoded"
    end

    test "an email without one has no encoded body" do
      assert ITipMessage.encoded_body(build_email()) == nil
    end
  end
end
