defmodule Ash.Notifier.LiveView do
  @moduledoc """
  Utilities for keeping ash query results up to date in a live view.
  """

  @type socket :: term
  @type assign :: atom
  @type assigns :: map
  @type topic :: String.t()
  @type liveness_options :: Keyword.t()

  require Logger

  @opts [
    subscribe: [
      type: {:custom, __MODULE__, :subscriptions, []},
      doc: "A topic or list of topics that should cause this data to update."
    ],
    refetch?: [
      type: :boolean,
      doc: "A boolean flag indicating whether a refetch is allowed to happen. Defaults to `true`"
    ],
    results: [
      type: {:one_of, [:keep, :lose]},
      doc:
        "For list and page queries, by default the records shown are never changed (unless the page changes)",
      default: :keep
    ],
    api: [
      type: :atom,
      doc:
        "For paginated views, in order to use `change_page/3`, you must set the Api to use for pagination"
    ],
    refetch_interval: [
      type: :non_neg_integer,
      doc: "An interval (in ms) to periodically refetch the query"
    ],
    refetch_window: [
      type: :non_neg_integer,
      doc:
        "The minimum time (in ms) between refetches, including refetches caused by notifications."
    ]
  ]

  @doc false
  def subscriptions(subscription) when is_binary(subscription), do: {:ok, subscription}

  def subscriptions(subscriptions) do
    if is_list(subscriptions) and Enum.all?(subscriptions, &is_binary/1) do
      {:ok, subscriptions}
    else
      {:error, "expected subscriptions to be a list of strings, got: #{inspect(subscriptions)}"}
    end
  end

  @doc """
  Runs the configured query and action, and stores the information required to keep it live in the socket assigns.

  The data will be assigned to the provided key, e.g `keep_live(socket, :me, ...)` would assign the results
  to `:me` (accessed as `@me` in the template).

  Additionally, you'll need to define a `handle_info/2` callback for your liveview to receive any
  notifications, and pass that notification into `handle_live/3`. See `handle_live/3` for more.

  ## Pagination

  To make paginated views convenient, as well as making it possible to keep those views live, Ash does not
  simply rerun the query when it gets an update, as that could involve shuffling the records around on the
  page. Eventually this will be configurable, but for now, Ash simply adjusts the query to only include the
  records that are on the page. If a record would be removed from a page due to a data change, it will simply
  be left there. For the best performance, use `keyset` pagination. If you *need* the ability to jump to a
  page by number, you'll want to use `offset` pagination, but keep in mind that it performs worse on large
  tables.

  To support this, accept a second parameter to your callback function, which will be the options to use in `page_opts`

  ## Options:
  #{NimbleOptions.docs(@opts)}

  A great way to get readable millisecond values, you can use the functions in erlang's `:timer` module,
  like `:timer.hours/1`, `:timer.minutes/1`, and `:timer.seconds/1`

  #### refetch_interval

  If this option is set, a message is sent as `{:refetch, assign_name, opts}` on that interval.
  You can then match on that event, like so:

  ```
  def handle_info({:refetch, assign, opts}, socket) do
    {:noreply, handle_live(socket, :refetch, assign, opts)}
  end
  ```

  This is the equivalent of `:timer.send_interval(interval, {:refetch, assign, opts})`, so feel free to
  roll your own solution if you have complex refetching requirements.

  #### refetch_window

  Normally, when a pubsub message is received the query is rerun. This option will cause the query to wait at least
  this amount of time before doing a refetch. This is accomplished with `Process.send_after/4`, and recording the
  last time each query was refetched. For example if a refetch happens at time `0`, and the `refetch_window` is
  10,000 ms, we would refetch, and record the time. Then if another refetch should happen 5,000 ms later, we would
  look and see that we need to wait another 5,000ms. So we use `Process.send_after/4` to send a
  `{:refetch, assign, opts}` message in 5,000ms. The time that a refetch was requested is tracked, so if the
  data has since been refetched, it won't be refetched again.

  #### Future Plans

  One interesting thing here is that, given that we know the scope of data that a resource cares about,
  we should be able to make optimizations to this code, to support partial refetches, or even just updating
  the data directly. However, this will need to be carefully considered, as the risks involve showing users
  data they could be unauthorized to see, or having state in the socket that is inconsistent.
  """

  require Ash.Query

  @type callback_result :: Ash.record() | list(Ash.record()) | Ash.page() | nil
  @type callback :: (socket -> callback_result) | (socket, Keyword.t() | nil -> callback_result)

  @spec keep_live(socket, assign, callback, liveness_options) :: socket
  def keep_live(socket, assign, callback, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @opts)

    if opts[:refetch_interval] do
      :timer.send_interval(opts[:refetch_interval], {:refetch, assign, []})
    end

    for topic <- List.wrap(opts[:subscribe]) do
      socket.endpoint.subscribe(topic)
    end

    live_config = Map.get(socket.assigns, :ash_live_config, %{})

    result =
      callback
      |> run_callback(socket, nil)
      |> mark_page_as_first()

    this_config = %{
      last_fetched_at: System.monotonic_time(:millisecond),
      callback: callback,
      opts: opts
    }

    socket
    |> Phoenix.LiveView.assign(assign, result)
    |> Phoenix.LiveView.assign(:ash_live_config, Map.put(live_config, assign, this_config))
  end

  def change_page(socket, assign, target) do
    live_config = socket.assigns.ash_live_config
    config = Map.get(live_config, assign)

    target =
      if target in ["prev", "next", "first", "last"] do
        String.to_existing_atom(target)
      else
        case Integer.parse(target) do
          {int, ""} ->
            int

          _ ->
            target
        end
      end

    current_page = Map.get(socket.assigns, assign)

    unless config.opts[:api] do
      raise "Must set api to use change_page/3"
    end

    new_result = config.opts[:api].page!(current_page, target)
    {_query, rerun_opts} = new_result.rerun
    new_page_opts = Keyword.merge(config.opts[:page] || [], rerun_opts[:page])
    new_opts = Keyword.put(config.opts, :page, new_page_opts)
    new_live_config = Map.update!(live_config, assign, &Map.put(&1, :opts, new_opts))

    socket
    |> Phoenix.LiveView.assign(assign, new_result)
    |> Phoenix.LiveView.assign(:ash_live_config, new_live_config)
  end

  def page_from_params(params, default_limit, count? \\ false) do
    params
    |> Kernel.||(%{})
    |> Map.take(["after", "before", "limit", "offset"])
    |> Enum.reject(fn {_, val} -> is_nil(val) || val == "" end)
    |> Enum.map(fn {key, value} -> {String.to_existing_atom(key), value} end)
    |> Enum.map(fn {key, value} ->
      case Integer.parse(value) do
        {int, ""} ->
          {key, int}

        _ ->
          {key, value}
      end
    end)
    |> Keyword.put_new(:limit, default_limit)
    |> Keyword.put(:count, count?)
  end

  def page_params(%Ash.Page.Keyset{} = keyset) do
    cond do
      keyset.after ->
        [after: keyset.after]

      keyset.before ->
        [before: keyset.before]

      true ->
        []
    end
  end

  def page_params(%Ash.Page.Offset{} = offset) do
    if offset.offset do
      [limit: offset.limit, offset: offset.offset]
    else
      [limit: offset.limit]
    end
  end

  def page_link_params(_, "first") do
    []
  end

  def page_link_params(%{__first__?: true}, "prev"), do: :invalid

  def page_link_params(%Ash.Page.Offset{more?: false}, "next"), do: :invalid

  def page_link_params(%Ash.Page.Keyset{more?: false, after: nil, before: before}, "prev")
      when not is_nil(before) do
    :invalid
  end

  def page_link_params(%Ash.Page.Keyset{more?: false, after: after_keyset, before: nil}, "next")
      when not is_nil(after_keyset) do
    :invalid
  end

  def page_link_params(%Ash.Page.Offset{} = offset, "next") do
    cond do
      offset.count && offset.offset + offset.limit >= offset.count ->
        :invalid

      Enum.count(offset.results) < offset.limit ->
        :invalid

      true ->
        [limit: offset.limit, offset: (offset.offset || 0) + offset.limit]
    end
  end

  def page_link_params(%Ash.Page.Offset{offset: 0}, "prev") do
    :invalid
  end

  def page_link_params(%Ash.Page.Offset{} = offset, "prev") do
    [limit: offset.limit, offset: max((offset.offset || 0) - offset.limit, 0)]
  end

  def page_link_params(%Ash.Page.Offset{count: count} = offset, "last") when not is_nil(count) do
    [offset: count - offset.limit, limit: offset.limit]
  end

  def page_link_params(%Ash.Page.Keyset{results: [], after: after_keyset} = keyset, "prev") do
    [before: after_keyset, limit: keyset.limit]
  end

  def page_link_params(%Ash.Page.Keyset{results: [], before: before_keyset} = keyset, "next") do
    [after: before_keyset, limit: keyset.limit]
  end

  def page_link_params(%Ash.Page.Keyset{results: [first | _]} = keyset, "prev") do
    [before: first.metadata.keyset, limit: keyset.limit]
  end

  def page_link_params(%Ash.Page.Keyset{results: results} = keyset, "next") do
    [after: List.last(results).metadata.keyset, limit: keyset.limit]
  end

  def page_link_params(%Ash.Page.Offset{count: count, limit: limit} = offset, target)
      when not is_nil(count) and is_integer(target) do
    target = max(target, 1)
    last_page = last_page(offset)
    target = min(target, last_page)

    [offset: (target - 1) * limit, limit: limit]
  end

  def page_link_params(_page, _target) do
    :invalid
  end

  def can_link_to_page?(page, target) do
    page_link_params(page, target) != :invalid
  end

  def last_page(%Ash.Page.Offset{count: count, limit: limit}) when is_integer(count) do
    if rem(count, limit) == 0 do
      div(count, limit)
    else
      div(count, limit) + 1
    end
  end

  def last_page(_), do: :unknown

  def on_page?(page, num) do
    page_number(page) == num
  end

  def page_number(%{offset: offset, limit: limit}) do
    if rem(offset, limit) == 0 do
      div(offset, limit)
    else
      div(offset, limit) + 1
    end
  end

  def page_number(_), do: false

  @doc """
  Incorporates an `Ash.Notifier.Notification` into the query results, based on the liveness configuration.

  You will want to match on receiving a notification from Ash, and the easiest way to do that is to match
  on the payload like so:

  ```
    @impl true
  def handle_info(%{topic: topic, payload: %Ash.Notifier.Notification{}}, socket) do
    {:noreply, handle_live(socket, topic, [:query1, :query2, :query3])}
  end
  ```

  Feel free to intercept notifications and do your own logic to respond to events. Ultimately, all
  that matters is that you also call `handle_live/3` if you want it to update your query results.

  The assign or list of assigns passed as the third argument must be the same names passed into
  `keep_live`. If you only want some queries to update based on some events, you can define multiple
  matches on events, and only call `handle_live/3` with the assigns that should be updated for that
  notification.
  """
  @spec handle_live(socket, topic | :refetch, assign | list(assign)) :: socket
  def handle_live(socket, notification, assigns, refetch_info \\ [])

  def handle_live(socket, notification, assigns, refetch_info) when is_list(assigns) do
    Enum.reduce(assigns, socket, &handle_live(&2, notification, &1, refetch_info))
  end

  def handle_live(socket, topic, assign, refetch_info) when is_binary(topic) do
    config = Map.get(socket.assigns.ash_live_config, assign)

    if config.opts[:subscribe] do
      if topic in List.wrap(config.opts[:subscribe]) do
        handle_live(socket, :refetch, assign, refetch_info)
      else
        socket
      end
    else
      handle_live(socket, :refetch, assign, refetch_info)
    end
  end

  def handle_live(socket, :refetch, assign, refetch_info) do
    config = Map.get(socket.assigns.ash_live_config, assign)

    diff = System.monotonic_time(:millisecond) - (config[:last_fetched_at] || 0)

    requested_before_last_refetch? =
      refetch_info[:requested_at] && refetch_info[:requested_at] <= config[:last_fetched_at]

    cond do
      requested_before_last_refetch? ->
        socket

      config[:refetch_window] && diff < config[:refetch_window] ->
        Process.send_after(
          self(),
          {:refetch, assign, [requested_at: System.monotonic_time(:millisecond)]},
          diff
        )

        socket

      true ->
        result =
          case Map.get(socket.assigns, assign) do
            %page_struct{} = page when page_struct in [Ash.Page.Keyset, Ash.Page.Offset] ->
              socket
              |> refetch_page(config.callback, page, config.opts)
              |> mark_page_as_first()

            list when is_list(list) ->
              refetch_list(socket, config.callback, list, config.opts)

            _ ->
              run_callback(config.callback, socket, nil)
          end

        new_config =
          config
          |> Map.put(:last_fetched_at, System.monotonic_time(:millisecond))

        new_full_config = Map.put(socket.assigns.ash_live_config, assign, new_config)

        socket
        |> Phoenix.LiveView.assign(assign, result)
        |> Phoenix.LiveView.assign(:ash_live_config, new_full_config)
    end
  end

  defp refetch_list(socket, callback, current_list, opts) do
    cond do
      opts[:results] == :lose ->
        run_callback(callback, socket, nil)

      current_list == [] ->
        []

      true ->
        nil

        first = List.first(current_list).__struct__
        pkey = Ash.Resource.primary_key(first)

        resulting_page = run_callback(callback, socket, nil)

        Enum.map(current_list, fn result ->
          Enum.find(
            resulting_page.results,
            result,
            &(Map.take(&1, pkey) == Map.take(result, pkey))
          )
        end)
    end
  end

  defp refetch_page(socket, callback, current_page, opts) do
    cond do
      opts[:results] == :lose ->
        run_callback(callback, socket, opts[:page])

      current_page.results == [] ->
        current_page

      true ->
        first = List.first(current_page.results).__struct__
        pkey = Ash.Resource.primary_key(first)

        filter =
          case pkey do
            [key] ->
              [{key, [in: Enum.map(current_page.results, &Map.get(&1, key))]}]

            keys ->
              [or: Enum.map(current_page.results, &Map.take(&1, keys))]
          end

        page_opts = Keyword.put(opts[:page] || [], :filter, filter)

        resulting_page = run_callback(callback, socket, page_opts)

        preserved_records =
          current_page.results
          |> Enum.map(fn result ->
            Enum.find(
              resulting_page.results,
              result,
              &(Map.take(&1, pkey) == Map.take(result, pkey))
            )
          end)

        %{resulting_page | results: preserved_records}
    end
  end

  defp run_callback(callback, socket, page_opts) when is_function(callback, 2) do
    callback.(socket, page_opts)
  end

  defp run_callback(callback, socket, _page_opts) when is_function(callback, 1) do
    callback.(socket)
  end

  defp mark_page_as_first(%Ash.Page.Keyset{} = page) do
    if page.after || page.before do
      page
    else
      Map.put(page, :__first__?, true)
    end
  end

  defp mark_page_as_first(%Ash.Page.Offset{} = page) do
    if is_nil(page.offset) || page.offset == 0 do
      Map.put(page, :__first__?, true)
    else
      page
    end
  end

  defp mark_page_as_first(page), do: page
end