defmodule NativeArtifact.Archive.Gzip do
  @moduledoc false

  alias NativeArtifact.Archive.Support

  @chunk_size 65_536

  def inflate(copy, spool, compressed_size, max_bytes, deadline) do
    bytes =
      Support.with_file(spool, [:raw, :binary, :write, :exclusive], :spool_create, fn output ->
        result = pass(copy, compressed_size, output, max_bytes, deadline, :complete)
        Support.io!(:file.sync(output), :spool_sync)
        result
      end)

    # The public inflater cuts at its first gzip member. A complete stream in
    # the size-minus-one prefix proves that the full copy had trailing bytes.
    # Both passes read the same private, previously hash-verified immutable copy.
    pass(copy, compressed_size - 1, nil, max_bytes, deadline, :incomplete)
    bytes
  end

  defp pass(copy, length, output, maximum, deadline, expectation) do
    Support.with_file(copy, [:raw, :binary, :read], :gzip_read, fn input ->
      z = :zlib.open()

      try do
        :ok = :zlib.inflateInit(z, 31)
        total = input_chunks(input, z, length, output, maximum, deadline, 0)

        completion =
          try do
            :zlib.inflateEnd(z)
          catch
            :error, :data_error -> :incomplete
          end

        case {expectation, completion} do
          {:complete, :ok} -> total
          {:incomplete, :incomplete} -> total
          {:complete, :incomplete} -> invalid(:truncated_gzip)
          {:incomplete, :ok} -> invalid(:trailing_gzip_data)
        end
      catch
        :error, :data_error -> invalid(:invalid_gzip)
      after
        :zlib.close(z)
      end
    end)
  end

  defp input_chunks(_input, _z, 0, _output, _maximum, _deadline, total), do: total

  defp input_chunks(input, z, remaining, output, maximum, deadline, total) do
    Support.deadline!(deadline)
    size = min(@chunk_size, remaining)

    case :file.read(input, size) do
      {:ok, bytes} when byte_size(bytes) == size ->
        total = output_chunks(z, bytes, output, maximum, deadline, total)
        input_chunks(input, z, remaining - size, output, maximum, deadline, total)

      {:ok, _bytes} ->
        invalid(:compressed_copy_changed)

      :eof ->
        invalid(:compressed_copy_changed)

      {:error, reason} ->
        invalid(reason)
    end
  end

  defp output_chunks(z, input, output, maximum, deadline, total) do
    Support.deadline!(deadline)

    case :zlib.safeInflate(z, input) do
      {status, bytes} when status in [:continue, :finished] ->
        total = total + :erlang.iolist_size(bytes)

        if total > maximum do
          Support.fail(:unsafe_archive, %{
            stage: :gzip,
            reason: :inflated_size_limit,
            maximum: maximum
          })
        end

        if output, do: Support.io!(:file.write(output, bytes), :spool_write)

        case status do
          :continue -> output_chunks(z, [], output, maximum, deadline, total)
          :finished -> total
        end

      {:need_dictionary, _adler, _bytes} ->
        invalid(:unsupported_dictionary)
    end
  end

  defp invalid(reason), do: Support.fail(:unsafe_archive, %{stage: :gzip, reason: reason})
end
