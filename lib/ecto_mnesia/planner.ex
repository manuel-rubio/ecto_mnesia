defmodule EctoMnesia.Planner do
  @moduledoc """
  Core Ecto Mnesia adapter implementation.
  """
  require Logger
  alias :mnesia, as: Mnesia
  alias EctoMnesia.{Record, Table}
  alias EctoMnesia.Record.{Context, Ordering, Update}
  alias EctoMnesia.Connection

  @behaviour Ecto.Adapter

  @required_apps [:mnesia]

  defmacro __before_compile__(_env), do: :ok

  def checkout(_adapter_meta, _config, function) do
    function.()
  end

  @doc """
  Ensure all applications necessary to run the adapter are started.
  """
  def ensure_all_started(_repo, type) do
    Enum.each(@required_apps, fn app ->
      {:ok, _} = Application.ensure_all_started(app, type)
    end)

    {:ok, @required_apps}
  end

  @doc """
  Returns the childspec that starts the adapter process.
  This method is called from `Ecto.Repo.Supervisor.init/2`.
  """
  def init(config) do
    #{:ok, Supervisor.Spec.supervisor(Supervisor, [[], [strategy: :one_for_one]]), %{}}
    {:ok, Connection.child_spec(config), %{}}
  end

  @doc """
  Automatically generate next ID for binary keys, leave sequence keys empty for generation on insert.
  """
  def autogenerate(:id), do: nil
  def autogenerate(:embed_id), do: Ecto.UUID.generate()
  def autogenerate(:binary_id), do: Ecto.UUID.autogenerate()

  @behaviour Ecto.Adapter.Queryable
  @doc """
  Prepares are called by Ecto before `execute/5` methods.
  """
  def prepare(operation, %Ecto.Query{sources: {{table, schema, _prefix}}, order_bys: order_bys, limit: limit} = query) do
    ordering_fn = Ordering.get_ordering_fn(order_bys)
    limit = get_limit(limit)
    limit_fn = if limit == nil, do: & &1, else: &Enum.take(&1, limit)
    context = Context.new(table, schema)
    {:nocache, {operation, query, {limit, limit_fn}, context, ordering_fn}}
  end

@doc """
  Perform `mnesia:select` on prepared query and convert the results to Ecto Schema.
  """
  def execute(
        _adapter_meta,
        %{sources: {{table, _schema, _prefix}}},
        {:nocache, {:all, %Ecto.Query{} = query, {limit, limit_fn}, context, ordering_fn}},
        params,
        _opts
      ) do
    context = Context.assign_query(context, query, params)
    match_spec = Context.get_match_spec(context)

    Logger.debug(fn ->
      "Selecting all records by match specification `#{inspect(match_spec)}` with limit #{inspect(limit)}"
    end)

    result =
      table
      |> Table.select(match_spec)
      |> ordering_fn.()
      |> limit_fn.()

    {length(result), result}
  end

  @doc """
  Deletes all records that match Ecto.Query
  """
  def execute(
        _repo,
        %{sources: {{table, _schema, _prefix}}},
        {:nocache, {:delete_all, %Ecto.Query{} = query, {limit, limit_fn}, context, ordering_fn}},
        params,
        opts
      ) do
    context = Context.assign_query(context, query, params)
    match_spec = Context.get_match_spec(context)

    Logger.debug(fn ->
      "Deleting all records by match specification `#{inspect(match_spec)}` with limit #{inspect(limit)}"
    end)

    table = Table.get_name(table)

    Table.transaction(fn ->
      table
      |> Table.select(match_spec)
      |> Enum.map(fn record ->
        {:ok, _} = Table.delete(table, List.first(record))
        record
      end)
      |> return_all(ordering_fn, {limit, limit_fn}, opts)
    end)
  end

  @doc """
  Update all records by a Ecto.Query.
  """
  def execute(
        _repo,
        %{sources: {{table, _schema, _prefix}}},
        {:nocache, {:update_all, %Ecto.Query{updates: updates} = query, {limit, limit_fn}, context, ordering_fn}},
        params,
        opts
      ) do
    context = Context.assign_query(context, query, params)
    match_spec = Context.get_match_spec(context)

    Logger.debug(fn ->
      "Updating all records by match specification `#{inspect(match_spec)}` with limit #{inspect(limit)}"
    end)

    table = Table.get_name(table)
    update = Update.update_record(updates, params, context)

    Table.transaction(fn ->
      table
      |> Table.select(match_spec)
      |> Enum.map(fn [record_id | _] ->
        {:ok, result} = Table.update(table, record_id, update)
        result
      end)
      |> return_all(ordering_fn, {limit, limit_fn}, opts)
    end)
  end

  # Constructs return for `*_all` methods.
  defp return_all(records, ordering_fn, {limit, limit_fn}, opts) do
    case Keyword.get(opts, :returning) do
      true ->
        result =
          records
          |> Enum.map(fn record ->
            record
            |> Tuple.to_list()
            |> List.delete_at(0)
          end)
          |> ordering_fn.()
          |> limit_fn.()

        {length(result), result}

      _ ->
        {min(limit, length(records)), nil}
    end
  end

  @doc false
  def stream(_, _, _, _, _),
    do: raise(ArgumentError, "stream/5 is not supported by adapter, use EctoMnesia.Table.Stream.new/2 instead")

  @doc """
  Insert Ecto Schema struct to Mnesia database.
  """
  def insert(
        _adapter_meta,
        %{autogenerate_id: autogenerate_id, schema: schema, source: table},
        params,
        _on_conflict,
        returning,
        _opts
      ) do
    case do_insert(table, schema, autogenerate_id, params) do
      {:ok, _fields} when returning == [] ->
        {:ok, []}

      {:ok, fields} ->
        {:ok, Keyword.take(fields, returning)}

      {:invalid, [{type, field} | _]} ->
        raise Ecto.ConstraintError,
          type: type,
          constraint: "#{type}.#{field}",
          changeset: Ecto.Changeset.change(%{__struct__: schema}),
          action: :insert
    end
  end

  @doc """
  Insert all
  """
  # TODO: deal with `opts`: `on_conflict` and `returning`
  def insert_all(
        adapter_meta,
        %{autogenerate_id: autogenerate_id, schema: schema, source: table},
        _header,
        rows,
        _on_conflict,
        returning,
        _opts
      ) do
    table = Table.get_name(table)

    result =
      Table.transaction(fn ->
        Enum.reduce(rows, {0, []}, &insert_record(&1, &2, adapter_meta, table, schema, autogenerate_id))
      end)

    case {result, returning} do
      {{:error, _reason}, _returning} ->
        {0, nil}

      {{count, _records}, []} ->
        {count, nil}

      {{count, records}, _returning} ->
        {count, records}
    end
  end

  defp insert_record(params, {index, acc}, adapter_meta, table, schema, autogenerate_id) do
    case do_insert(table, schema, autogenerate_id, params) do
      {:ok, record} ->
        {index + 1, [record] ++ acc}

      {:invalid, [{:unique, _pk_field}]} ->
        rollback(adapter_meta, nil)

      {:error, _reason} ->
        rollback(adapter_meta, nil)
    end
  end

  # Insert schema without primary keys
  defp do_insert(table, schema, nil, params) do
    record = Record.new(schema, table, params)

    case Mnesia.transaction(fn ->
      case Table.insert(table, record) do
        {:ok, ^record} ->
          {:ok, params}
        {:error, reason} ->
          {:error, reason}
      end
    end) do
      {:atomic, res} -> res
      {:abort, reason} -> {:error, reason}
    end
  end

  # Insert schema with auto-generating primary key value
  defp do_insert(table, schema, {pk_field, _source_field, _pk_type}, params) do
    params = put_new_pk(params, pk_field, table)
    record = Record.new(schema, table, params)

    case Mnesia.transaction(fn ->
      case Table.insert(table, record) do
        {:ok, ^record} ->
          {:ok, params}
        {:error, :already_exists} ->
          {:invalid, [{:unique, pk_field}]}
        {:error, reason} ->
          {:error, reason}
      end
    end) do
      {:atomic, res} -> res
      {:abort, reason} -> {:error, reason}
    end
  end

  # Generate new sequenced primary key for table
  defp put_new_pk(params, pk_field, table) when is_list(params) and is_atom(pk_field) do
    {_, params} =
      Keyword.get_and_update(params, pk_field, fn
        nil -> {nil, Table.next_id(table)}
        val -> {val, val}
      end)

    params
  end

  @doc """
  Run `fun` inside a Mnesia transaction
  """
  def transaction(_adapter_meta, _opts, fun) do
    case Table.transaction(fun) do
      {:error, reason} ->
        {:error, reason}

      result ->
        {:ok, result}
    end
  end

  @doc """
  Returns true when called inside a transaction.
  """
  def in_transaction?(_adapter_meta), do: Mnesia.is_transaction()

  @doc """
  Transaction rollbacks is not fully supported.
  """
  def rollback(_adapter_meta, _tid), do: Mnesia.abort(:rollback)

  @doc """
  Deletes a record from a Mnesia database.
  """
  def delete(_adapter_meta, %{schema: schema, source: table, autogenerate_id: _autogenerate_id}, filter, _opts) do
    pk = get_pk!(filter, schema.__schema__(:primary_key))

    case Table.delete(table, pk) do
      {:ok, ^pk} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Updates record stored in a Mnesia database.
  """
  def update(
        _adapter_meta,
        %{schema: schema, source: table, autogenerate_id: _autogenerate_id},
        changes,
        filter,
        returning,
        _opts
      ) do
    pk = get_pk!(filter, schema.__schema__(:primary_key))
    context = Context.new(table, schema)
    update = Update.from_keyword(schema, table, changes, context)

    case Table.update(table, pk, update) do
      {:ok, _record} when returning == [] ->
        {:ok, []}

      {:ok, _record} ->
        {:ok, changes}
      error -> error
    end
  end

  # Extract primary key value or raise an error
  defp get_pk!(params, {pk_field, _pk_type}), do: get_pk!(params, pk_field)
  defp get_pk!(params, [pk_field]), do: get_pk!(params, pk_field)

  defp get_pk!(params, pk_field) do
    case Keyword.fetch(params, pk_field) do
      :error -> raise Ecto.NoPrimaryKeyValueError
      {:ok, pk} -> pk
    end
  end

  # Extract limit from an `Ecto.Query`
  defp get_limit(nil), do: nil
  defp get_limit(%Ecto.Query.QueryExpr{expr: limit}), do: limit

  # Required methods for Ecto type casing
  def loaders({:embed, _value} = primitive, _type), do: [&Ecto.Adapters.SQL.load_embed(primitive, &1)]
  def loaders(:binary_id, type), do: [Ecto.UUID, type]
  def loaders(_primitive, type), do: [type]

  def dumpers({:embed, _value} = primitive, _type), do: [&Ecto.Adapters.SQL.dump_embed(primitive, &1)]
  def dumpers(:binary_id, type), do: [type, Ecto.UUID]
  def dumpers(_primitive, type), do: [type]
end
