defmodule EctoMnesia.Connection do
  @moduledoc false
  use GenServer
  alias :mnesia, as: Mnesia

  @pk_table_name :id_seq

  def start_link(config) do
    GenServer.start_link(__MODULE__, [config], name: __MODULE__)
  end

  def init([config]) do
    Process.flag(:trap_exit, true)
    :mnesia.stop()
    :mnesia.create_schema(config[:nodes] || [node()])
    :mnesia.start()
    ensure_pk_table!(Keyword.get(config, :repo))
    {:ok, config}
  end

  def terminate(_reason, state) do
    spawn fn ->
      try do
        :dets.sync(@pk_table_name)
        state
      rescue
        e -> e
      end
    end
  end

  defp ensure_pk_table!(repo) do
    res =
      try do
        Mnesia.table_info(:size, @pk_table_name)
      catch
        :exit, {:aborted, {:no_exists, :size, _}} -> :no_exists
      end

    case res do
      :no_exists ->
        do_create_table(repo, @pk_table_name, :set, [:thing, :id])

      _ ->
        Mnesia.wait_for_tables([@pk_table_name], 1_000)
        :ok
    end
  end

  defp do_create_table(repo, table, type, attributes) do
    config = EctoMnesia.Storage.conf(repo.config)
    attributes =
      if length(attributes) == 1 do
        attributes ++ [:__hidden]
      else
        attributes
      end

    tab_def = [{:attributes, attributes}, {config[:storage_type], [config[:host]]}, {:type, get_engine(type)}]
    table = if String.valid?(table), do: String.to_atom(table), else: table

    case Mnesia.create_table(table, tab_def) do
      {:atomic, :ok} ->
        Mnesia.wait_for_tables([table], 1_000)
        :ok

      {:aborted, {:already_exists, ^table}} ->
        :already_exists
    end
  end

  defp get_engine(nil), do: :ordered_set
  defp get_engine(type) when is_atom(type), do: type

end
