defmodule KogasaFrontend.Chat.RateLimiter do
  @moduledoc false
  use GenServer

  @table :kogasa_frontend_rate_limits
  @counted_table :kogasa_frontend_counted_rate_limits

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def allow?(key, ttl_seconds)
      when is_binary(key) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    now = System.system_time(:second)
    expires_at = now + ttl_seconds

    case :ets.lookup(@table, key) do
      [{^key, existing_expiry}] when existing_expiry > now ->
        false

      _ ->
        :ets.insert(@table, {key, expires_at})
        true
    end
  end

  def allow_count?(key, limit, window_seconds)
      when is_binary(key) and is_integer(limit) and limit > 0 and
             is_integer(window_seconds) and window_seconds > 0 do
    GenServer.call(__MODULE__, {:allow_count, key, limit, window_seconds})
  end

  @impl true
  def init(state) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(@counted_table, [
      :named_table,
      :protected,
      :set,
      read_concurrency: true
    ])

    schedule_cleanup()
    {:ok, state}
  end

  @impl true
  def handle_call({:allow_count, key, limit, window_seconds}, _from, state) do
    now = System.system_time(:second)
    cutoff = now - window_seconds

    recent =
      case :ets.lookup(@counted_table, key) do
        [{^key, _expires_at, timestamps}] ->
          Enum.filter(timestamps, &(&1 > cutoff))

        _ ->
          []
      end

    if length(recent) >= limit do
      {:reply, false, state}
    else
      :ets.insert(@counted_table, {key, now + window_seconds, [now | recent]})
      {:reply, true, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{:"$1", :"$2"}, [{:<, :"$2", now}], [true]}])

    :ets.select_delete(@counted_table, [
      {{:"$1", :"$2", :"$3"}, [{:<, :"$2", now}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, :timer.seconds(30))
  end
end
