defmodule Sheetshow.Xlsx.StylesTest do
  use ExUnit.Case, async: true

  doctest Sheetshow.Xlsx.Styles

  alias Sheetshow.Xlsx.{Strings, Styles}

  describe "what a number format says a value is" do
    test "the letters that can only mean a date" do
      for code <- ["yyyy", "dd/mm", "d-mmm-yy", "yyyy-mm-dd"],
          do: assert(Styles.kind(code) == :date)
    end

    test "the letters that can only mean a time" do
      for code <- ["h:mm", "ss.0", "[h]:mm:ss", "mm:ss.0"], do: assert(Styles.kind(code) == :time)
    end

    test "both together" do
      for code <- ["yyyy-mm-dd hh:mm", "m/d/yy h:mm AM/PM"],
          do: assert(Styles.kind(code) == :datetime)
    end

    test "m on its own decides nothing, because it is month and minute both" do
      assert Styles.kind("mm") == nil
    end

    test "a letter inside quotes is text, not a field" do
      assert Styles.kind(~s("day" 0)) == nil
      assert Styles.kind(~s(0" hours")) == nil
    end

    test "a letter escaped with a backslash is text too" do
      assert Styles.kind(~S(0\d)) == nil
    end

    test "a colour or a condition in brackets is not an elapsed-time field" do
      assert Styles.kind("[Red]0.00") == nil
      assert Styles.kind("[>100]0;0") == nil
    end

    test "only the first section counts: the rest is for negatives and zero" do
      assert Styles.kind("yyyy;@") == :date
      assert Styles.kind("0.00;[Red]0.00") == nil
    end
  end

  describe "a workbook with no styles.xml" do
    test "every index is plain" do
      styles = Styles.new()

      assert Styles.fetch(styles, 0) == %{style: %{}, kind: nil}
      assert Styles.fetch(styles, 7) == %{style: %{}, kind: nil}
      assert Styles.fetch(styles, nil) == %{style: %{}, kind: nil}
    end
  end

  describe "built-in number formats" do
    setup do
      xml = """
      <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <cellXfs count="5">
      <xf numFmtId="0" fontId="0" fillId="0"/>
      <xf numFmtId="14" fontId="0" fillId="0"/>
      <xf numFmtId="21" fontId="0" fillId="0"/>
      <xf numFmtId="22" fontId="0" fillId="0"/>
      <xf numFmtId="4" fontId="0" fillId="0"/>
      </cellXfs></styleSheet>
      """

      {:ok, styles} = Styles.parse(xml)
      %{styles: styles}
    end

    test "are known without the file spelling them out", %{styles: styles} do
      assert Styles.fetch(styles, 1).kind == :date
      assert Styles.fetch(styles, 2).kind == :time
      assert Styles.fetch(styles, 3).kind == :datetime
      assert Styles.fetch(styles, 4).kind == nil
    end

    test "and bring their pattern with them", %{styles: styles} do
      assert Styles.fetch(styles, 1).style == %{number_format: "mm-dd-yy"}
      assert Styles.fetch(styles, 4).style == %{number_format: "#,##0.00"}
      assert Styles.fetch(styles, 0).style == %{}
    end
  end

  describe "styles a cell does not point at" do
    test "cellStyleXfs holds xf elements that are not what a cell indexes into" do
      xml = """
      <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <fonts count="2"><font/><font><b/></font></fonts>
      <cellStyleXfs count="1"><xf numFmtId="0" fontId="1" fillId="0"/></cellStyleXfs>
      <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" xfId="0"/></cellXfs>
      </styleSheet>
      """

      {:ok, styles} = Styles.parse(xml)

      assert map_size(styles.formats) == 1
      assert Styles.fetch(styles, 0).style == %{}
    end

    test "a theme colour needs a part we do not read, so it is left out" do
      xml = """
      <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <fonts count="2"><font/><font><color theme="4"/><b/></font></fonts>
      <cellXfs count="2"><xf fontId="0"/><xf fontId="1"/></cellXfs>
      </styleSheet>
      """

      {:ok, styles} = Styles.parse(xml)

      assert Styles.fetch(styles, 1).style == %{bold: true}
    end

    test "a fill whose pattern is none is no background, whatever colour it names" do
      xml = """
      <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <fills count="2">
      <fill><patternFill patternType="none"><fgColor rgb="FFFF0000"/></patternFill></fill>
      <fill><patternFill patternType="solid"><fgColor rgb="FF00FF00"/></patternFill></fill>
      </fills>
      <cellXfs count="2"><xf fillId="0"/><xf fillId="1"/></cellXfs>
      </styleSheet>
      """

      {:ok, styles} = Styles.parse(xml)

      assert Styles.fetch(styles, 0).style == %{}
      assert Styles.fetch(styles, 1).style == %{background: "#00FF00"}
    end
  end

  describe "shared strings" do
    test "a table of plain strings" do
      xml = ~s(<sst><si><t>one</t></si><si><t>two</t></si></sst>)
      {:ok, strings} = Strings.parse(xml)

      assert Strings.size(strings) == 2
      assert Strings.fetch(strings, 0) == "one"
      assert Strings.fetch(strings, 1) == "two"
    end

    test "text formatted a piece at a time reads as one string" do
      xml = ~s(<sst><si><r><t>bold </t></r><r><t>and plain</t></r></si></sst>)
      {:ok, strings} = Strings.parse(xml)

      assert Strings.fetch(strings, 0) == "bold and plain"
    end

    test "phonetic hints beside a run are not part of the string" do
      xml = ~s(<sst><si><t>東京</t><rPh sb="0" eb="2"><t>トウキョウ</t></rPh></si></sst>)
      {:ok, strings} = Strings.parse(xml)

      assert Strings.fetch(strings, 0) == "東京"
    end

    test "whitespace a writer asked to keep is kept" do
      xml = ~s[<sst><si><t xml:space="preserve">  padded  </t></si></sst>]
      {:ok, strings} = Strings.parse(xml)

      assert Strings.fetch(strings, 0) == "  padded  "
    end

    test "an index off either end is nil rather than an error" do
      {:ok, strings} = Strings.parse(~s(<sst><si><t>one</t></si></sst>))

      assert Strings.fetch(strings, 1) == nil
      assert Strings.fetch(strings, -1) == nil
    end

    test "an empty table" do
      assert Strings.size(Strings.new()) == 0
      assert Strings.fetch(Strings.new(), 0) == nil
    end
  end
end
