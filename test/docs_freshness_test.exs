defmodule ApmV5.DocsFreshnessTest do
  use ExUnit.Case, async: true

  @current_version "9.1.3"
  @docs_root "priv/docs"

  describe "versions.json" do
    test "latest field equals current version" do
      path = Path.join(@docs_root, "versions.json")
      data = path |> File.read!() |> Jason.decode!()
      assert data["latest"] == @current_version,
        "versions.json latest is #{data["latest"]}, expected #{@current_version}"
    end

    test "current version entry exists" do
      path = Path.join(@docs_root, "versions.json")
      data = path |> File.read!() |> Jason.decode!()
      versions = Enum.map(data["versions"] || [], & &1["version"])
      assert @current_version in versions,
        "versions.json missing entry for #{@current_version}"
    end
  end

  describe "docs.json" do
    test "version field equals current version" do
      path = Path.join(@docs_root, "docs.json")
      data = path |> File.read!() |> Jason.decode!()
      assert data["version"] == @current_version,
        "docs.json version is #{data["version"]}, expected #{@current_version}"
    end
  end

  describe "index.md" do
    test "version header is current" do
      content = File.read!(Path.join(@docs_root, "index.md"))
      assert String.contains?(content, "**Version #{@current_version}**") or
             String.contains?(content, "Version #{@current_version}"),
        "index.md does not declare Version #{@current_version} in header"
    end

    test "What's New section references current version" do
      content = File.read!(Path.join(@docs_root, "index.md"))
      assert String.contains?(content, "v#{@current_version}"),
        "index.md What's New section does not reference v#{@current_version}"
    end
  end

  describe "sidebar_nav.ex" do
    test "@app_version is current" do
      content = File.read!("lib/apm_v5_web/components/sidebar_nav.ex")
      assert String.contains?(content, ~s|@app_version "#{@current_version}"|),
        "sidebar_nav.ex @app_version is not #{@current_version}"
    end
  end

  describe "changelog.md" do
    test "header references current version" do
      content = File.read!(Path.join(@docs_root, "changelog.md"))
      first_200 = String.slice(content, 0, 200)
      assert String.contains?(first_200, @current_version),
        "changelog.md header (first 200 chars) does not reference #{@current_version}"
    end
  end

  describe "developer/api-reference.md" do
    test "opening version declaration is current" do
      content = File.read!(Path.join(@docs_root, "developer/api-reference.md"))
      first_100 = String.slice(content, 0, 100)
      assert String.contains?(first_100, @current_version),
        "api-reference.md opening line does not declare #{@current_version}"
    end
  end

  describe "developer/liveview-pages.md" do
    test "Version field in header is current" do
      content = File.read!(Path.join(@docs_root, "developer/liveview-pages.md"))
      first_200 = String.slice(content, 0, 200)
      assert String.contains?(first_200, @current_version),
        "liveview-pages.md version header is not #{@current_version}"
    end
  end

  describe "user/skills.md" do
    test "version declaration is current" do
      content = File.read!(Path.join(@docs_root, "user/skills.md"))
      first_300 = String.slice(content, 0, 300)
      assert String.contains?(first_300, @current_version),
        "user/skills.md version header is not #{@current_version}"
    end
  end

  describe "user/usage.md" do
    test "version declaration is current" do
      content = File.read!(Path.join(@docs_root, "user/usage.md"))
      first_200 = String.slice(content, 0, 200)
      assert String.contains?(first_200, @current_version),
        "user/usage.md version header is not #{@current_version}"
    end
  end

  describe "user/getting-started.md" do
    test "version declaration is current" do
      content = File.read!(Path.join(@docs_root, "user/getting-started.md"))
      first_200 = String.slice(content, 0, 200)
      assert String.contains?(first_200, @current_version),
        "user/getting-started.md version header is not #{@current_version}"
    end
  end
end
