defmodule NativeArtifact.ManifestSchemaTest do
  use ExUnit.Case, async: true

  alias NativeArtifact.Target

  @schema_path Path.expand("../../native/artifacts.schema.json", __DIR__)
  @fixture_path Path.expand("../fixtures/manifest-v1.json", __DIR__)

  setup_all do
    {:ok,
     schema: @schema_path |> File.read!() |> JSON.decode!(),
     fixture: @fixture_path |> File.read!() |> JSON.decode!()}
  end

  test "v1 fails closed on schema versions, required features and unknown core fields", %{
    schema: schema
  } do
    assert %{
             "$schema" => "https://json-schema.org/draft/2020-12/schema",
             "additionalProperties" => false,
             "properties" => %{
               "schema_version" => %{"const" => 1},
               "required_features" => %{"maxItems" => 0}
             },
             "$defs" => %{
               "artifact" => %{
                 "additionalProperties" => false,
                 "properties" => %{"kind" => %{"const" => "nif"}}
               },
               "file" => %{"properties" => %{"type" => %{"const" => "regular"}}}
             }
           } = schema

    assert schema["required"] -- Map.keys(schema["properties"]) == []

    assert Enum.sort(schema["$defs"]["artifact"]["required"]) ==
             schema["$defs"]["artifact"]["properties"]
             |> Map.keys()
             |> List.delete("extensions")
             |> Enum.sort()
  end

  test "every local schema reference resolves", %{schema: schema} do
    for "#/$defs/" <> name <- references(schema) do
      assert Map.has_key?(schema["$defs"], name), "unresolved schema definition #{name}"
    end
  end

  test "example identifies itself as non-production and supplies a complete target", %{
    fixture: fixture
  } do
    assert %{
             "schema_version" => 1,
             "required_features" => [],
             "extensions" => %{"native_artifact:example" => %{"non_production" => true}},
             "artifacts" => [artifact]
           } = fixture

    assert {:ok, %Target{os: :linux, arch: :x86_64, libc: :glibc}} =
             Target.new(artifact["target"])

    assert [%{"type" => "https", "url" => url}, %{"type" => "local"}] = artifact["sources"]
    assert URI.parse(url).host == "example.invalid"
    assert artifact["archive"]["sha256"] == String.duplicate("0", 64)
  end

  test "example file identities cover the NIF, private libraries and licenses", %{
    fixture: fixture
  } do
    [artifact] = fixture["artifacts"]
    files = Map.new(artifact["files"], &{&1["path"], &1})
    assert map_size(files) == length(artifact["files"])
    assert %{"type" => "regular", "role" => "nif"} = files[artifact["entrypoint"]]

    for path <- artifact["private_libraries"] do
      assert %{"type" => "regular", "role" => "private_library"} = files[path]
    end

    for %{"file" => path} <- artifact["licenses"] do
      assert %{"type" => "regular", "role" => "license"} = files[path]
    end

    for {path, file} <- files do
      refute Path.type(path) == :absolute
      refute ".." in Path.split(path)
      assert file["size"] >= 0
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, file["sha256"])
    end
  end

  # These checks cover contract consistency, not full JSON Schema validation.
  defp references(value) when is_map(value) do
    own = if Map.has_key?(value, "$ref"), do: [value["$ref"]], else: []
    own ++ Enum.flat_map(Map.values(value), &references/1)
  end

  defp references(value) when is_list(value), do: Enum.flat_map(value, &references/1)
  defp references(_value), do: []
end
