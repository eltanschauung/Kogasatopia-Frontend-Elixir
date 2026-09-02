defmodule KogasaFrontend.Chat.IpBanTest do
  use ExUnit.Case, async: true

  alias KogasaFrontend.Chat.IpBan

  test "normalizes IPv4 clients to a /16 subnet" do
    assert IpBan.subnet_for_ip("172.56.14.9") == "172.56.0.0/16"
    assert IpBan.subnet_for_ip({172, 56, 14, 9}) == "172.56.0.0/16"
  end

  test "normalizes IPv4-mapped IPv6 clients to the same IPv4 subnet" do
    assert IpBan.subnet_for_ip({0, 0, 0, 0, 0, 65_535, 44_088, 3_593}) ==
             "172.56.0.0/16"
  end

  test "normalizes native IPv6 clients to a /64 subnet" do
    assert IpBan.subnet_for_ip({0x2001, 0x0DB8, 0x1234, 0x5678, 1, 2, 3, 4}) ==
             "2001:db8:1234:5678::/64"
  end
end
