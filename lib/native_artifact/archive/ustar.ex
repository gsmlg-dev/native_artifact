defmodule NativeArtifact.Archive.Ustar do
  @moduledoc false

  alias NativeArtifact.Archive.Support

  @block_size 512

  def verify(spool, tar_size, files, directories, limits, deadline) do
    Support.with_file(spool, [:raw, :binary, :read], :tar_read, fn input ->
      scan(input, 0, tar_size, files, directories, limits, deadline, %{}, MapSet.new(), 0, 0)
    end)
  end

  defp scan(
         input,
         offset,
         tar_size,
         files,
         directories,
         limits,
         deadline,
         found,
         seen,
         count,
         dirs
       ) do
    Support.deadline!(deadline)
    block = Support.read_exact!(input, offset, @block_size, :tar_header)

    if Support.zero?(block) do
      ending = Support.read_exact!(input, offset + @block_size, @block_size, :tar_end)
      if not Support.zero?(ending), do: invalid(:invalid_tar_end)
      verify_tail(input, offset + 2 * @block_size, tar_size, deadline)

      if map_size(found) != map_size(files) do
        invalid(:missing_files)
      end

      found |> Map.values() |> Enum.sort_by(& &1.path)
    else
      if count >= limits.max_headers, do: invalid(:header_count_limit)
      header = header(block)
      path = header.path
      if MapSet.member?(seen, path), do: invalid(:duplicate_path)
      seen = MapSet.put(seen, path)
      data_offset = offset + @block_size

      case header.type do
        :directory ->
          if dirs >= limits.max_directories, do: invalid(:directory_count_limit)
          if not MapSet.member?(directories, path), do: invalid(:unnecessary_directory)
          if header.size != 0, do: invalid(:directory_payload)
          if header.mode != 0o755, do: invalid(:directory_mode)

          scan(
            input,
            data_offset,
            tar_size,
            files,
            directories,
            limits,
            deadline,
            found,
            seen,
            count + 1,
            dirs + 1
          )

        :regular ->
          file = Map.get(files, path) || invalid(:unlisted_file)
          if header.size != file["size"], do: invalid(:file_size_mismatch)
          if header.mode != String.to_integer(file["mode"], 8), do: invalid(:file_mode_mismatch)
          padding = rem(@block_size - rem(header.size, @block_size), @block_size)
          next = data_offset + header.size + padding
          if next > tar_size, do: invalid(:truncated_tar)
          digest = Support.hash_region(input, data_offset, header.size, deadline)

          if digest != file["sha256"] do
            Support.fail(:checksum_mismatch, %{stage: :file, path: path, field: :sha256})
          end

          pad = Support.read_exact!(input, data_offset + header.size, padding, :tar_padding)
          if not Support.zero?(pad), do: invalid(:nonzero_file_padding)

          entry = %{
            path: path,
            offset: data_offset,
            size: header.size,
            mode: header.mode,
            sha256: digest
          }

          scan(
            input,
            next,
            tar_size,
            files,
            directories,
            limits,
            deadline,
            Map.put(found, path, entry),
            seen,
            count + 1,
            dirs
          )
      end
    end
  end

  defp header(block) do
    checksum = octal(binary_part(block, 148, 8))
    <<before::binary-size(148), _checksum::binary-size(8), after_checksum::binary>> = block
    expected = Enum.sum(:binary.bin_to_list(before <> :binary.copy(" ", 8) <> after_checksum))
    if checksum != expected, do: invalid(:tar_checksum)

    if binary_part(block, 257, 6) != "ustar\0" or binary_part(block, 263, 2) != "00" do
      invalid(:unsupported_tar_format)
    end

    type =
      case :binary.at(block, 156) do
        0 -> :regular
        ?0 -> :regular
        ?5 -> :directory
        _other -> invalid(:unsupported_tar_type)
      end

    if not Support.zero?(binary_part(block, 157, 100)), do: invalid(:link_target)
    if not Support.zero?(binary_part(block, 500, 12)), do: invalid(:extra_header_metadata)
    if octal(binary_part(block, 329, 8), true) != 0, do: invalid(:device_metadata)
    if octal(binary_part(block, 337, 8), true) != 0, do: invalid(:device_metadata)
    octal(binary_part(block, 108, 8))
    octal(binary_part(block, 116, 8))
    octal(binary_part(block, 136, 12))
    field(binary_part(block, 265, 32))
    field(binary_part(block, 297, 32))
    name = field(binary_part(block, 0, 100))
    prefix = field(binary_part(block, 345, 155))
    name = if prefix == "", do: name, else: prefix <> "/" <> name

    path =
      if type == :directory and String.ends_with?(name, "/") do
        binary_part(name, 0, byte_size(name) - 1)
      else
        name
      end

    if not Support.safe_path?(path), do: invalid(:unsafe_path)

    %{
      type: type,
      path: path,
      size: octal(binary_part(block, 124, 12)),
      mode: octal(binary_part(block, 100, 8))
    }
  end

  defp octal(field, allow_empty \\ false) do
    value = field |> :binary.bin_to_list() |> Enum.drop_while(&(&1 == 32))
    {digits, rest} = Enum.split_while(value, &(&1 in ?0..?7))

    if (digits == [] and not allow_empty) or Enum.any?(rest, &(&1 not in [0, 32])) do
      invalid(:invalid_numeric_field)
    end

    Enum.reduce(digits, 0, fn digit, value -> value * 8 + digit - ?0 end)
  end

  defp field(binary) do
    case :binary.match(binary, <<0>>) do
      :nomatch ->
        binary

      {offset, 1} ->
        suffix = binary_part(binary, offset, byte_size(binary) - offset)
        if not Support.zero?(suffix), do: invalid(:embedded_header_data)
        binary_part(binary, 0, offset)
    end
  end

  defp verify_tail(input, offset, size, deadline) do
    if rem(size - offset, @block_size) != 0, do: invalid(:unaligned_tar_padding)
    tail(input, offset, size - offset, deadline)
  end

  defp tail(_input, _offset, 0, _deadline), do: :ok

  defp tail(input, offset, remaining, deadline) when remaining > 0 do
    Support.deadline!(deadline)
    size = min(65_536, remaining)
    bytes = Support.read_exact!(input, offset, size, :tar_end)
    if not Support.zero?(bytes), do: invalid(:data_after_tar_end)
    tail(input, offset + size, remaining - size, deadline)
  end

  defp invalid(reason), do: Support.fail(:unsafe_archive, %{stage: :tar, reason: reason})
end
