defmodule Longpi.Agent.SkillsTest do
  use ExUnit.Case, async: true

  alias Longpi.Agent.Skills

  @moduletag :tmp_dir

  defp write_skill(dir, name, description, body \\ "Do the thing.") do
    skill_dir = Path.join([dir, ".longpi/skills", name])
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: #{name}
    description: #{description}
    ---
    #{body}
    """)
  end

  test "discovers project skills from <cwd>/.longpi/skills/<name>/SKILL.md", %{tmp_dir: dir} do
    write_skill(dir, "pdf-forms", "Fill PDF form fields")
    write_skill(dir, "csv-clean", "Normalize messy CSVs")

    skills = Skills.discover(dir)
    assert Enum.map(skills, & &1.name) == ["csv-clean", "pdf-forms"]
    assert Enum.find(skills, &(&1.name == "pdf-forms")).description == "Fill PDF form fields"
    assert Enum.find(skills, &(&1.name == "pdf-forms")).path =~ "pdf-forms/SKILL.md"
  end

  test "a directory without a SKILL.md is ignored", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join([dir, ".longpi/skills", "empty"]))
    assert Skills.discover(dir) == []
  end

  test "a SKILL.md missing required frontmatter is skipped", %{tmp_dir: dir} do
    bad = Path.join([dir, ".longpi/skills", "broken"])
    File.mkdir_p!(bad)
    File.write!(Path.join(bad, "SKILL.md"), "no frontmatter here")

    assert Skills.discover(dir) == []
  end

  test "no skills dir → empty", %{tmp_dir: dir} do
    assert Skills.discover(dir) == []
  end
end
