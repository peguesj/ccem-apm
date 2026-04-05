defmodule ApmV5.NativeTransport.UnixSocketTest do
  use ExUnit.Case, async: false

  alias ApmV5.NativeTransport.UnixSocket

  @test_path "/tmp/ccem-apm-test-#{System.unique_integer([:positive])}.sock"

  setup do
    {:ok, pid} = UnixSocket.start_link(path: @test_path, name: {:global, make_ref()})
    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      _ = File.rm(@test_path)
    end)

    # Wait for socket file to exist
    wait_for_socket(@test_path, 20)
    %{path: @test_path}
  end

  test "round-trips a ping/pong frame", %{path: path} do
    {:ok, sock} =
      :gen_tcp.connect({:local, path}, 0, [:binary, {:packet, :raw}, {:active, false}])

    ref = make_ref()
    assert :ok = UnixSocket.send_frame(sock, {:ping, ref})
    assert {:ok, {:pong, ^ref}} = UnixSocket.recv_frame(sock, 1_000)
    :gen_tcp.close(sock)
  end

  test "handles hello handshake", %{path: path} do
    {:ok, sock} =
      :gen_tcp.connect({:local, path}, 0, [:binary, {:packet, :raw}, {:active, false}])

    assert :ok = UnixSocket.send_frame(sock, {:hello, %{version: "1.0"}})
    assert {:ok, {:hello_ack, ack}} = UnixSocket.recv_frame(sock, 1_000)
    assert ack.server == "apm_v5"
    assert ack.client == %{version: "1.0"}
    :gen_tcp.close(sock)
  end

  defp wait_for_socket(_path, 0), do: flunk("socket file never appeared")
  defp wait_for_socket(path, n) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(25)
      wait_for_socket(path, n - 1)
    end
  end
end
