defmodule NativeArtifact.Installer.Receipt do
  @moduledoc false

  alias NativeArtifact.Installer.Support
  alias NativeArtifact.Manifest.JSON, as: ManifestJSON

  def build(data, artifact) do
    artifact_receipt =
      artifact
      |> Map.take(
        ~w(id kind native_version build_revision target compatibility binding archive provenance)
      )
      |> Map.put("entrypoint", "payload/" <> artifact["entrypoint"])
      |> Map.put(
        "files",
        artifact["files"]
        |> Enum.map(&Map.update!(&1, "path", fn path -> "payload/" <> path end))
        |> Enum.sort_by(& &1["path"])
      )

    canonical(%{
      "receipt_version" => 1,
      "mode" => "precompiled",
      "manifest_schema_version" => 1,
      "package" => data["package"],
      "package_version" => data["package_version"],
      "artifact" => artifact_receipt
    })
  end

  defp canonical(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, canonical(item)} end)

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value) when is_float(value) and trunc(value) == value, do: trunc(value)
  defp canonical(value), do: value

  def write(directory, receipt) do
    path = Path.join(directory, "receipt.json")

    Support.with_file(path, [:raw, :binary, :write, :exclusive], :receipt_create, fn file ->
      Support.io!(:file.write(file, JSON.encode!(receipt)), :receipt_write)
      Support.io!(File.chmod(path, 0o644), :receipt_mode)
      Support.io!(:file.sync(file), :receipt_sync)
    end)
  end

  def max_bytes(receipt), do: byte_size(JSON.encode!(receipt)) + 1024

  def verify(directory, receipt, deadline) do
    maximum = max_bytes(receipt)
    bytes = Support.read_bounded(Path.join(directory, "receipt.json"), maximum, deadline)
    limits = %{max_manifest_bytes: maximum, max_depth: 16, max_nodes: maximum + 1}

    case ManifestJSON.decode(bytes, limits) do
      {:ok, ^receipt} ->
        :ok

      _other ->
        Support.fail(:checksum_mismatch, %{stage: :installed_receipt, reason: :identity_mismatch})
    end
  end
end
