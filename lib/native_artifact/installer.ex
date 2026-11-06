defmodule NativeArtifact.Installer do
  @moduledoc """
  Transactional local-byte installation of an exact Manifest v1 artifact.

  This internal boundary revalidates the complete manifest but does not resolve
  runtime compatibility. It reads only a supplied local archive or a fully
  verified existing installation. Network/cache access, native loading, source
  compilation and Mix `priv` symlink handling are separate boundaries.

  Files live under the physical application-owned `priv_dir` at
  `native/<package>/<package_version>/<artifact_id>/<archive_sha256>/`, with a
  separate `payload/` directory and portable `receipt.json`. A unique sibling
  staging tree is promoted only after all bytes, metadata and receipt are ready.
  """

  alias NativeArtifact.{Archive, Error, Manifest}
  alias NativeArtifact.Installer.{Receipt, Support, Verifier}

  @defaults %{priv_dir: nil, manifest_limits: [], archive_limits: [], timeout: 180_000}

  @doc """
  Installs exact local bytes or reuses a completely verified immutable directory.

  Required `:priv_dir` is an existing normalized physical absolute directory.
  Optional `:manifest_limits` and `:archive_limits` pass finite supported limits
  to those boundaries; `:timeout` bounds total local work (default 180,000 ms).
  Returned absolute paths are conveniences; persisted receipt paths are relative.
  """
  @spec install(Manifest.t() | map(), binary(), binary(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def install(manifest, artifact_id, archive_path, opts \\ []) do
    try do
      config = configuration(opts, @defaults, MapSet.new())

      archive_limits =
        archive_limits(config.archive_limits, Archive.default_limits(), MapSet.new())

      deadline = System.monotonic_time(:millisecond) + config.timeout

      data =
        case manifest do
          %Manifest{data: data} -> data
          data -> data
        end

      %Manifest{data: data} = Support.unwrap(Manifest.validate(data, config.manifest_limits))
      artifact = select(data, artifact_id)
      Support.absolute!(archive_path, :archive_path)
      Support.physical_directory!(config.priv_dir)
      receipt = Receipt.build(data, artifact)
      tree = Verifier.tree(receipt, archive_limits)
      components = ["native", data["package"], data["package_version"], artifact["id"]]
      Enum.each(components ++ [artifact["archive"]["sha256"]], &segment!/1)

      parent =
        Enum.reduce(components, config.priv_dir, fn component, parent ->
          Support.deadline!(deadline)
          path = Path.join(parent, component)
          Support.ensure_directory!(path)
          path
        end)

      final = Path.join(parent, artifact["archive"]["sha256"])

      case File.lstat(final) do
        {:ok, _info} ->
          Verifier.verify(final, receipt, tree, deadline)
          {:ok, result(final, artifact, receipt, true)}

        {:error, :enoent} ->
          fresh(
            parent,
            final,
            archive_path,
            artifact,
            receipt,
            tree,
            archive_limits,
            deadline,
            config.priv_dir
          )

        {:error, reason} ->
          Support.fail(:unsafe_archive, %{stage: :installation, reason: reason})
      end
    catch
      {:native_artifact_installer, error} -> {:error, error}
    end
  end

  defp configuration([], config, _seen) do
    if not is_integer(config.timeout) or config.timeout <= 0 do
      invalid(:timeout)
    end

    config
  end

  defp configuration([{key, value} | rest], config, seen) do
    if not Map.has_key?(@defaults, key) or MapSet.member?(seen, key), do: invalid(:options)
    configuration(rest, Map.put(config, key, value), MapSet.put(seen, key))
  end

  defp configuration(_opts, _config, _seen), do: invalid(:options)

  defp archive_limits([], limits, _seen), do: limits

  defp archive_limits([{key, value} | rest], limits, seen) do
    if not Map.has_key?(limits, key) or MapSet.member?(seen, key) or
         not is_integer(value) or value <= 0 do
      invalid(:archive_limits)
    end

    archive_limits(rest, Map.put(limits, key, value), MapSet.put(seen, key))
  end

  defp archive_limits(_opts, _limits, _seen), do: invalid(:archive_limits)

  defp select(data, artifact_id) do
    if not is_binary(artifact_id), do: invalid(:artifact_id)

    Enum.find(data["artifacts"], &(&1["id"] == artifact_id)) ||
      Support.fail(:artifact_not_found, %{stage: :installation, reason: :unknown_artifact})
  end

  defp segment!(segment) do
    if not is_binary(segment) or byte_size(segment) not in 1..255 or
         segment in [".", ".."] or not Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._+-]*\z/, segment) do
      invalid(:namespace_component)
    end
  end

  defp fresh(parent, final, archive_path, artifact, receipt, tree, limits, deadline, priv) do
    stage =
      Path.join(
        parent,
        ".install-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    Support.io!(File.mkdir(stage), :installation_stage)

    try do
      Support.io!(File.chmod(stage, 0o700), :installation_stage_mode)
      Support.deadline!(deadline)
      remaining = deadline - System.monotonic_time(:millisecond)
      if remaining <= 0, do: Support.deadline!(deadline)

      archive_options =
        limits |> Map.put(:timeout, min(limits.timeout, remaining)) |> Map.to_list()

      Support.unwrap(
        Archive.extract(archive_path, artifact, Path.join(stage, "payload"), archive_options)
      )

      Receipt.write(stage, receipt)
      Support.io!(File.chmod(Path.join(stage, "payload"), 0o755), :payload_mode)
      Support.io!(File.chmod(stage, 0o755), :installation_stage_mode)
      Verifier.verify(stage, receipt, tree, deadline)
      Verifier.sync(stage, tree, deadline)
      Support.deadline!(deadline)

      case File.rename(stage, final) do
        :ok ->
          sync_parents(parent, priv, deadline)
          {:ok, result(final, artifact, receipt, false)}

        {:error, reason} ->
          case File.lstat(final) do
            {:ok, _info} ->
              Verifier.verify(final, receipt, tree, deadline)
              {:ok, result(final, artifact, receipt, true)}

            {:error, _other} ->
              Support.fail(:unsafe_archive, %{stage: :installation_promote, reason: reason})
          end
      end
    after
      Support.remove_stage!(stage)
    end
  end

  defp sync_parents(path, priv, deadline) do
    Support.deadline!(deadline)
    Support.sync_directory(path, :promotion_sync)
    if path != priv, do: sync_parents(Path.dirname(path), priv, deadline)
  end

  defp result(directory, artifact, receipt, reused?) do
    %{
      directory: directory,
      payload_directory: Path.join(directory, "payload"),
      entrypoint: Path.join([directory, "payload", artifact["entrypoint"]]),
      receipt: receipt,
      reused?: reused?
    }
  end

  defp invalid(reason),
    do: Support.fail(:invalid_configuration, %{stage: :installation, reason: reason})
end
