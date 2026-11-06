defmodule NativeArtifact.Test.LocalArchiveFixture do
  @moduledoc false

  def file(path, body, opts \\ []) do
    %{
      "path" => path,
      "type" => "regular",
      "role" => Keyword.get(opts, :role, "data"),
      "size" => byte_size(body),
      "sha256" => sha256(body),
      "mode" => Keyword.get(opts, :mode, "0644")
    }
  end

  def entry(path, body, opts \\ []) do
    %{name: path, body: body, opts: opts}
  end

  def tar(entries, tail \\ :binary.copy(<<0>>, 1024)) do
    entries
    |> Enum.map(fn %{body: body} = entry ->
      [header(entry), body, :binary.copy(<<0>>, padding(byte_size(body)))]
    end)
    |> then(&IO.iodata_to_binary([&1, tail]))
  end

  def header(%{name: name, body: body, opts: opts}) do
    header =
      IO.iodata_to_binary([
        field(name, 100),
        octal(Keyword.get(opts, :mode, 0o644), 8),
        octal(0, 8),
        octal(0, 8),
        octal(Keyword.get(opts, :size, byte_size(body)), 12),
        octal(0, 12),
        :binary.copy(" ", 8),
        Keyword.get(opts, :type, "0"),
        field(Keyword.get(opts, :link, ""), 100),
        Keyword.get(opts, :magic, "ustar\0"),
        "00",
        field("", 32),
        field("", 32),
        octal(0, 8),
        octal(0, 8),
        field(Keyword.get(opts, :prefix, ""), 155),
        :binary.copy(<<0>>, 12)
      ])

    sum = header |> :binary.bin_to_list() |> Enum.sum()
    checksum = sum |> Integer.to_string(8) |> String.pad_leading(6, "0")
    replace(header, 148, 8, checksum <> <<0, 32>>)
  end

  def replace(binary, offset, length, replacement) do
    <<before::binary-size(offset), _old::binary-size(length), rest::binary>> = binary
    before <> replacement <> rest
  end

  def write(root, files, tar, opts \\ []) do
    gzip = Keyword.get_lazy(opts, :gzip, fn -> :zlib.gzip(tar) end)
    path = Path.join(root, "archive.tar.gz")
    File.write!(path, gzip)

    artifact = %{
      "entrypoint" => files |> Enum.find(&(&1["role"] == "nif")) |> Map.fetch!("path"),
      "files" => files,
      "archive" => %{
        "format" => "tar.gz",
        "size" => byte_size(gzip),
        "sha256" => sha256(gzip)
      }
    }

    {path, artifact}
  end

  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  def padding(size), do: rem(512 - rem(size, 512), 512)

  def temporary_directory do
    root =
      System.tmp_dir!()
      |> physical_path()
      |> Path.join("native-artifact-archive-" <> Base.url_encode64(:crypto.strong_rand_bytes(12)))

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    root
  end

  defp physical_path(path) do
    Enum.reduce(Path.split(Path.expand(path)), "", fn component, parent ->
      current = if parent == "", do: component, else: Path.join(parent, component)

      case File.read_link(current) do
        {:ok, target} -> physical_path(Path.expand(target, Path.dirname(current)))
        {:error, _reason} -> current
      end
    end)
  end

  defp field(value, size) when byte_size(value) <= size do
    value <> :binary.copy(<<0>>, size - byte_size(value))
  end

  defp octal(value, size) do
    (value |> Integer.to_string(8) |> String.pad_leading(size - 1, "0")) <> <<0>>
  end
end
