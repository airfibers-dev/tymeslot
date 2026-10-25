defmodule Tymeslot.Mailer.SMTPAdapterEncodedBodyTest do
  @moduledoc """
  `Tymeslot.Mailer.SMTPAdapter`'s pre-encoded path, against a scripted relay:
  the bytes an iTIP invitation was encoded into are what reach the wire, and
  an email without one is still encoded by Swoosh exactly as before.

  The envelope is asserted here too, because the encoded body carries no `Bcc`
  header: the blind recipients have to come from the email struct.
  """

  use ExUnit.Case, async: false

  @moduletag :emails
  @moduletag :mailer
  @moduletag :integration

  import Tymeslot.ConfigTestHelpers

  alias Swoosh.Email
  alias Tymeslot.Mailer.ITipMessage
  alias Tymeslot.Mailer.SMTPConfig
  alias Tymeslot.Test.FakeSmtpRelay

  @calendar "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nEND:VCALENDAR\r\n"

  defp email do
    Email.new(
      to: [{"Guest", "guest@example.com"}],
      from: {"Tymeslot", "noreply@example.com"},
      subject: "Appointment Confirmed",
      text_body: "Plain-text body.",
      html_body: "<p>HTML body.</p>"
    )
  end

  defp encoded_body(email) do
    ITipMessage.encode(email, %{
      text: email.text_body,
      html: email.html_body,
      calendar: @calendar,
      calendar_method: "REQUEST",
      logo: nil
    })
  end

  defp use_relay(relay) do
    config =
      [host: "localhost", port: relay.port, username: "user", password: "pass"]
      |> SMTPConfig.build()

    setup_config(:tymeslot, Tymeslot.Mailer, config)
  end

  test "sends the pre-encoded body verbatim" do
    relay = FakeSmtpRelay.start()
    use_relay(relay)

    email = email()
    body = encoded_body(email)

    assert {:ok, _receipt} =
             email
             |> ITipMessage.put_encoded_body(body)
             |> Tymeslot.Mailer.deliver()

    assert_receive {:smtp_relay, {:message, data}}, 2_000
    assert data == body
    assert data =~ "Content-Type: text/calendar; charset=\"utf-8\"; method=REQUEST"
    refute data =~ "Content-Disposition: attachment"
  end

  test "without a stashed body, Swoosh encodes the email as before" do
    relay = FakeSmtpRelay.start()
    use_relay(relay)

    assert {:ok, _receipt} = Tymeslot.Mailer.deliver(email())

    assert_receive {:smtp_relay, {:message, data}}, 2_000
    assert data =~ "Subject: Appointment Confirmed"
    assert data =~ "Plain-text body."
    refute data =~ "text/calendar"
  end

  test "the envelope takes To, Cc and Bcc from the email, and Bcc stays out of the message" do
    relay = FakeSmtpRelay.start()
    use_relay(relay)

    email =
      email()
      |> Email.cc([{"Copy", "copy@example.com"}])
      |> Email.bcc([{"Blind", "blind@example.com"}])

    assert {:ok, _receipt} =
             email
             |> ITipMessage.put_encoded_body(encoded_body(email))
             |> Tymeslot.Mailer.deliver()

    assert_receive {:smtp_relay, {:message, data}}, 2_000
    assert data =~ "To: \"Guest\" <guest@example.com>"
    assert data =~ "Cc: \"Copy\" <copy@example.com>"
    refute data =~ "blind@example.com"
    refute data =~ "Bcc:"
  end
end
