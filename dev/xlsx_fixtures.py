#!/usr/bin/env python3
"""Rebuild the two .xlsx fixtures the decoder is tested against.

They are committed as binaries, so this is how they stay auditable: run it and
the files should come back the same but for their timestamps.

Two writers on purpose, because they disagree about almost everything that
matters to a reader. openpyxl puts a cell's text in the cell as `t="inlineStr"`
and ships no shared string table at all; xlsxwriter shares its strings the way
Excel does. openpyxl writes `t="n"` on every number; xlsxwriter writes no type
attribute. openpyxl writes relationship targets absolute from the package root;
xlsxwriter writes them relative. A decoder that handles one and not the other
looks finished right up until someone opens the wrong file.

    pip install openpyxl xlsxwriter
    python3 dev/xlsx_fixtures.py

Both hold the same spreadsheet: a Costs sheet of twelve cells covering string,
number, boolean, date, datetime, time, formula and escaped text, with a bold
coloured font, a fill, an alignment and two number formats between them; a
column width and a row height; and a second, empty sheet called log.
"""

import os
from datetime import date, datetime, time

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(os.path.dirname(HERE), "test", "fixtures")


def openpyxl_fixture(path):
    import openpyxl
    from openpyxl.styles import Alignment, Font, PatternFill

    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Costs"

    ws["A1"] = "Item"
    ws["A1"].font = Font(bold=True, size=13, name="Calibri", color="FF1155CC")
    ws["B1"] = "Cost"
    ws["B1"].fill = PatternFill("solid", fgColor="FFFFF2CC")
    ws["C1"] = "When"
    ws["C1"].alignment = Alignment(horizontal="center", vertical="top", wrapText=True)

    ws["A2"] = "Rent"
    ws["B2"] = 1000
    ws["C2"] = date(2026, 9, 13)
    ws["A3"] = True
    ws["B3"] = 12.5
    ws["B3"].number_format = "#,##0.00"
    ws["C3"] = datetime(2026, 9, 13, 8, 30, 0)
    ws["A4"] = time(14, 45)
    ws["B4"] = "=B2*2"
    ws["C4"] = "a string with <angle> & ampersand"

    ws.column_dimensions["A"].width = 18.5
    ws.row_dimensions[2].height = 30

    wb.create_sheet("log")
    wb.save(path)


def xlsxwriter_fixture(path):
    import xlsxwriter

    wb = xlsxwriter.Workbook(path, {"default_date_format": "yyyy-mm-dd"})
    bold = wb.add_format({"bold": True, "font_size": 13, "font_color": "#1155CC"})
    fill = wb.add_format({"bg_color": "#FFF2CC"})
    centred = wb.add_format({"align": "center", "valign": "top", "text_wrap": True})
    money = wb.add_format({"num_format": "#,##0.00"})
    stamp = wb.add_format({"num_format": "yyyy-mm-dd hh:mm:ss"})

    ws = wb.add_worksheet("Costs")
    ws.write_string(0, 0, "Item", bold)
    ws.write_string(0, 1, "Cost", fill)
    ws.write_string(0, 2, "When", centred)
    ws.write_string(1, 0, "Rent")
    ws.write_number(1, 1, 1000)
    ws.write_datetime(1, 2, date(2026, 9, 13))
    ws.write_boolean(2, 0, True)
    ws.write_number(2, 1, 12.5, money)
    ws.write_datetime(2, 2, datetime(2026, 9, 13, 8, 30, 0), stamp)
    # A cached result, which openpyxl does not write: a formula's <v> is what
    # the writing program last worked it out to, and may be absent or stale.
    ws.write_formula(3, 1, "=B2*2", None, 2000)
    # A repeat of "Rent", so the string table is actually shared.
    ws.write_string(3, 2, "Rent")

    ws.set_column(0, 0, 18.5)
    ws.set_row(1, 30)
    wb.add_worksheet("log")
    wb.close()


def duration_fixture(path):
    # An elapsed duration, formatted [hh]:mm:ss, which is a count of hours and
    # not a time of day: 36 hours is the serial number 1.5. A reader that treats
    # it as a Time throws the whole days away, turning 1.5 into 0.5. openpyxl
    # applies the elapsed format to a timedelta on its own.
    import openpyxl
    from datetime import timedelta

    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Data"
    ws["A1"] = timedelta(hours=36)
    wb.save(path)


if __name__ == "__main__":
    openpyxl_fixture(os.path.join(FIXTURES, "openpyxl.xlsx"))
    xlsxwriter_fixture(os.path.join(FIXTURES, "xlsxwriter.xlsx"))
    duration_fixture(os.path.join(FIXTURES, "duration.xlsx"))
    print("wrote openpyxl.xlsx, xlsxwriter.xlsx and duration.xlsx to", FIXTURES)
