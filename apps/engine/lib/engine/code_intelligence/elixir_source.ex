defmodule Engine.CodeIntelligence.ElixirSource do
  @moduledoc """
  Resolves definitions for Elixir standard library modules and functions.

  This module handles finding the source location of Elixir built-in modules
  and functions by parsing the Elixir installation source files.
  """

  alias Forge.Document.Location
  alias Forge.Document.Position
  alias Forge.Document.Range
  alias Forge.Document

  require Logger

  @doc """
  Finds the definition of an Elixir standard library function or module.

  Returns `{:ok, Location.t()}` if found, `{:ok, nil}` otherwise.

  ## Examples

      iex> find_definition(:module, String)
      {:ok, %Location{}}

      iex> find_definition(:call, String, :capitalize, 1)
      {:ok, %Location{}}
  """
  @spec find_definition(:module | :call, module(), atom() | nil, non_neg_integer() | nil) ::
          {:ok, Location.t() | nil} | {:error, String.t()}
  def find_definition(type, module, function \\ nil, arity \\ nil)

  def find_definition(:module, module, _function, _arity) do
    with {:ok, source_path} <- get_module_source_path(module),
         true <- File.exists?(source_path),
         {:ok, line, column} <- find_module_definition(source_path, module) do
      build_location(source_path, line, column)
    else
      false ->
        Logger.debug("Source file not found for module #{inspect(module)}")
        {:ok, nil}

      {:error, _} = error ->
        error

      nil ->
        {:ok, nil}
    end
  end

  def find_definition(:call, module, function, arity)
      when is_atom(module) and is_atom(function) and is_integer(arity) do
    with {:ok, source_path} <- get_module_source_path(module),
         true <- File.exists?(source_path),
         {:ok, line, column} <- find_function_definition(source_path, function, arity) do
      build_location(source_path, line, column)
    else
      false ->
        Logger.debug("Source file not found for module #{inspect(module)}")
        {:ok, nil}

      {:error, reason} = error ->
        Logger.error("ElixirSource: Error finding definition: #{inspect(reason)}")
        error

      nil ->
        Logger.debug("ElixirSource: No definition found")
        {:ok, nil}
    end
  end

  def find_definition(_, _, _, _), do: {:ok, nil}

  # Get the source file path for an Elixir module
  defp get_module_source_path(module) do
    try do
      case module.module_info(:compile)[:source] do
        source when is_list(source) ->
          # The source in module_info is from the build machine
          # We need to map it to the actual Elixir installation
          source_file = Path.basename(to_string(source))
          lib_dir = :code.lib_dir(:elixir)
          local_path = Path.join([to_string(lib_dir), "lib", source_file])
          {:ok, local_path}

        _ ->
          {:error, "No source information available for #{inspect(module)}"}
      end
    rescue
      error ->
        {:error, "Failed to get source path: #{inspect(error)}"}
    end
  end

  # Find the line and column where a module is defined
  defp find_module_definition(source_path, module) do
    module_name = module |> Module.split() |> List.last() |> String.to_atom()

    with {:ok, source} <- File.read(source_path),
         {:ok, ast} <- Code.string_to_quoted(source, columns: true, token_metadata: true) do
      result =
        Macro.prewalk(ast, nil, fn
          {:defmodule, meta, [{:__aliases__, _, parts}, _body]} = node, nil ->
            if List.last(parts) == module_name do
              {node, {:found, meta[:line], meta[:column]}}
            else
              {node, nil}
            end

          node, acc ->
            {node, acc}
        end)

      case result do
        {_, {:found, line, column}} -> {:ok, line, column}
        _ -> nil
      end
    end
  end

  # Find the line and column where a function is defined
  defp find_function_definition(source_path, function, arity) do
    with {:ok, source} <- File.read(source_path),
         {:ok, ast} <- Code.string_to_quoted(source, columns: true, token_metadata: true) do
      # Find all definitions of this function
      {_ast, definitions} =
        Macro.prewalk(ast, [], fn
          # Match function with when clause: def foo(args) when guard
          {def_type, _meta, [{:when, _, [{^function, fun_meta, args}, _guard]}, _body]} = node,
          acc
          when def_type in [:def, :defp, :defmacro, :defmacrop] ->
            def_arity = if args == nil, do: 0, else: count_required_args(args)
            location = %{line: fun_meta[:line], column: fun_meta[:column], arity: def_arity}
            {node, [location | acc]}

          # Match function without when clause: def foo(args)
          {def_type, _meta, [{^function, fun_meta, args}, _body]} = node, acc
          when def_type in [:def, :defp, :defmacro, :defmacrop] ->
            def_arity = if args == nil, do: 0, else: count_required_args(args)
            location = %{line: fun_meta[:line], column: fun_meta[:column], arity: def_arity}
            {node, [location | acc]}

          node, acc ->
            {node, acc}
        end)

      # Find the definition that matches the arity (considering default arguments)
      case find_matching_definition(definitions, arity) do
        %{line: line, column: column} -> {:ok, line, column}
        _ -> nil
      end
    end
  end

  # Count required arguments (excluding those with defaults)
  defp count_required_args(args) do
    Enum.count(args, fn
      {:\\, _, _} -> false
      _ -> true
    end)
  end

  # Find a definition that matches the given arity
  # A function with default args can match multiple arities
  defp find_matching_definition(definitions, target_arity) do
    # Reverse to get definitions in source order
    definitions = Enum.reverse(definitions)

    # First, try to find an exact match on the minimum arity
    # A function like def foo(a, b \\ 1) has min_arity=1 and max_arity=2
    # and should match both foo/1 and foo/2
    Enum.find(definitions, fn %{arity: def_arity} ->
      def_arity <= target_arity
    end) ||
      # If no match, return the first definition
      List.first(definitions)
  end

  # Build a Location struct from file path and position
  defp build_location(source_path, line, column) do
    uri = Document.Path.ensure_uri(source_path)

    case Document.Store.open_temporary(uri) do
      {:ok, document} ->
        position = Position.new(document, line, column)

        # Get the text at this line to determine the precise range
        case Document.fetch_text_at(document, line) do
          {:ok, text} ->
            range = to_precise_range(document, text, line, column)
            {:ok, Location.new(range, document)}

          _ ->
            # Fallback to just the position
            range = Range.new(position, position)
            {:ok, Location.new(range, document)}
        end

      error ->
        Logger.error("Failed to open document: #{inspect(error)}")
        {:error, "Could not open source file: #{source_path}"}
    end
  end

  # Convert line/column to a precise range covering the token
  defp to_precise_range(document, text, line, column) do
    case Code.Fragment.surround_context(text, {line, column}) do
      %{begin: start_pos, end: end_pos} ->
        to_range(document, start_pos, end_pos)

      _ ->
        # Fallback to just the position
        pos = Position.new(document, line, column)
        Range.new(pos, pos)
    end
  end

  defp to_range(document, {start_line, start_col}, {end_line, end_col}) do
    Range.new(
      Position.new(document, start_line, start_col),
      Position.new(document, end_line, end_col)
    )
  end
end
