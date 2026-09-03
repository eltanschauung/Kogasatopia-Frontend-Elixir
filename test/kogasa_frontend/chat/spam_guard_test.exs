defmodule KogasaFrontend.Chat.SpamGuardTest do
  use ExUnit.Case, async: true

  alias KogasaFrontend.Chat.SpamGuard

  test "normalizes presentation differences and repeated graphemes for fingerprints" do
    assert SpamGuard.normalize_for_fingerprint("  WOOOOOOW  ") ==
             SpamGuard.normalize_for_fingerprint("wooow")

    assert SpamGuard.normalize_for_fingerprint("GIBS") ==
             SpamGuard.normalize_for_fingerprint("gibs")
  end

  test "normalizes variable-length private-use floods to one fingerprint" do
    private_use = <<0x10FFFD::utf8>>

    assert SpamGuard.normalize_for_fingerprint(String.duplicate(private_use, 30)) ==
             SpamGuard.normalize_for_fingerprint(String.duplicate(private_use, 60))
  end

  test "detects low-diversity and private-use floods" do
    private_use = <<0x10FFFD::utf8>>

    assert SpamGuard.suspicious_content?(String.duplicate("x", 12))
    assert SpamGuard.suspicious_content?(String.duplicate(private_use, 30))
    refute SpamGuard.suspicious_content?("This is a normal webchat message.")
  end

  test "requires both automatic-ban terms in the same message" do
    assert SpamGuard.automatic_ban_content?("CHILD safety: block porn")
    assert SpamGuard.automatic_ban_content?("pornographic child content")
    refute SpamGuard.automatic_ban_content?("child safety")
    refute SpamGuard.automatic_ban_content?("porn filtering")
  end
end
