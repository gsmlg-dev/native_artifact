defmodule NativeArtifact.Installer.Verifier do
  @moduledoc false

  alias NativeArtifact.Installer.{Receipt, Support}

  def tree(receipt, limits) do
    files = receipt["artifact"]["files"]

    if length(files) > limits.max_files or
         Enum.reduce(files, 0, &(&1["size"] + &2)) > limits.max_unpacked_bytes or
         receipt["artifact"]["archive"]["size"] > limits.max_archive_bytes do
      Support.fail(:invalid_manifest, %{stage: :installation, reason: :archive_limits})
    end

    directories =
      Enum.reduce(files, MapSet.new(["", "payload"]), fn file, directories ->
        file["path"]
        |> String.split("/")
        |> Enum.drop(-1)
        |> Enum.reduce({"", directories}, fn component, {parent, directories} ->
          parent = if parent == "", do: component, else: parent <> "/" <> component
          directories = MapSet.put(directories, parent)

          if MapSet.size(directories) - 2 > limits.max_directories do
            Support.fail(:invalid_manifest, %{stage: :installation, reason: :directory_limit})
          end

          {parent, directories}
        end)
        |> elem(1)
      end)

    nodes =
      Map.new(files, &{&1["path"], {:file, &1}})
      |> Map.put("receipt.json", :receipt)

    nodes = Enum.reduce(directories, nodes, &Map.put(&2, &1, :directory))

    children =
      nodes
      |> Map.keys()
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce(%{}, fn path, children ->
        parent =
          case Path.dirname(path) do
            "." -> ""
            parent -> parent
          end

        Map.update(
          children,
          parent,
          MapSet.new([Path.basename(path)]),
          &MapSet.put(&1, Path.basename(path))
        )
      end)

    %{nodes: nodes, children: children, directories: directories}
  end

  def verify(directory, receipt, tree, deadline) do
    verify_node(directory, "", receipt, tree, deadline)
    Receipt.verify(directory, receipt, deadline)
  end

  defp verify_node(root, relative, receipt, tree, deadline) do
    Support.deadline!(deadline)
    path = if relative == "", do: root, else: Path.join(root, relative)

    info =
      case File.lstat(path) do
        {:ok, info} -> info
        {:error, reason} -> unsafe(reason)
      end

    case Map.fetch!(tree.nodes, relative) do
      :directory ->
        if info.type != :directory, do: unsafe(:unexpected_file_type)
        if Bitwise.band(info.mode, 0o7777) != 0o755, do: unsafe(:directory_mode)
        expected = Map.get(tree.children, relative, MapSet.new())
        names = Support.io!(File.ls(path), :installed_directory)

        if length(names) != MapSet.size(expected) or MapSet.new(names) != expected do
          unsafe(:unexpected_membership)
        end

        Enum.each(names, fn name ->
          child = if relative == "", do: name, else: relative <> "/" <> name
          verify_node(root, child, receipt, tree, deadline)
        end)

      :receipt ->
        regular!(info, 0o644)
        if info.size > Receipt.max_bytes(receipt), do: mismatch(:receipt_size)

      {:file, file} ->
        regular!(info, String.to_integer(file["mode"], 8))
        if info.size != file["size"], do: mismatch(:size)

        if Support.hash_file(path, file["size"], deadline) != file["sha256"],
          do: mismatch(:sha256)
    end
  end

  defp regular!(info, mode) do
    if info.type != :regular or info.links != 1, do: unsafe(:unexpected_file_type)
    if Bitwise.band(info.mode, 0o7777) != mode, do: mismatch(:mode)
  end

  def sync(directory, tree, deadline) do
    Enum.each(tree.nodes, fn {relative, kind} ->
      if kind != :directory do
        Support.deadline!(deadline)
        Support.sync_file(Path.join(directory, relative))
      end
    end)

    tree.directories
    |> Enum.sort_by(&(-length(String.split(&1, "/"))))
    |> Enum.each(fn relative ->
      Support.deadline!(deadline)
      path = if relative == "", do: directory, else: Path.join(directory, relative)
      Support.sync_directory(path, :installation_sync)
    end)
  end

  defp unsafe(reason),
    do: Support.fail(:unsafe_archive, %{stage: :installed_tree, reason: reason})

  defp mismatch(field),
    do: Support.fail(:checksum_mismatch, %{stage: :installed_file, field: field})
end
