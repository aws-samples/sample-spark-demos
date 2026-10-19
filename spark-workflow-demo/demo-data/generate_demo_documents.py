#!/usr/bin/env python3
"""Generate synthetic application documents for the SPARK Workflow demo.

Produces a ZIP with two German PDFs for a FICTIONAL plan approval procedure
(Planfeststellungsverfahren) "Ortsumgehung Musterhausen (B 999n)":

  01_Erlaeuterungsbericht_Ortsumgehung_Musterhausen.pdf
      Explanatory report: project description, justification (traffic
      figures table), alternatives (site plan figure), technical data table.
  19-1_Umweltbericht_Kurzfassung_Ortsumgehung_Musterhausen.pdf
      Environmental report summary: protected species table, noise levels
      figure, mitigation measures table.

The content deliberately exercises the AI analysis pipeline:
  - multi-page German text with headings   -> extraction + chunking
  - tables                                 -> docling table path + VLM
  - vector figures                         -> docling picture path + VLM
  - species names                          -> species/scale extraction
  - "Erlaeuterungsbericht" in the filename -> metadata priority keyword

All data is synthetic: fictional places, roads, and organizations; every
page carries a disclaimer footer.

Usage:
    python3 -m venv /tmp/pdfgen && /tmp/pdfgen/bin/pip install reportlab==4.2.5
    /tmp/pdfgen/bin/python generate_demo_documents.py [--out-dir .]

Requires: reportlab (no other third-party packages).
"""

from __future__ import annotations

import argparse
import zipfile
from pathlib import Path

from reportlab.graphics.shapes import Circle, Drawing, Group, Line, PolyLine, Polygon, Rect, String
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

DISCLAIMER = "Synthetische Demodaten – fiktives Verfahren, keine realen Orte, Personen oder Vorhaben"
PROJECT = "Ortsumgehung Musterhausen (B 999n)"
APPLICANT = "Landesbetrieb Straßenbau Musterland, Niederlassung Beispielstadt"
DATE = "15. Juli 2026"

ZIP_NAME = "antragsunterlagen-ortsumgehung-musterhausen.zip"
PDF_1 = "01_Erlaeuterungsbericht_Ortsumgehung_Musterhausen.pdf"
PDF_2 = "19-1_Umweltbericht_Kurzfassung_Ortsumgehung_Musterhausen.pdf"

# --- styles -----------------------------------------------------------------

_styles = getSampleStyleSheet()
H1 = ParagraphStyle("H1x", parent=_styles["Heading1"], fontSize=14, spaceAfter=6)
H2 = ParagraphStyle("H2x", parent=_styles["Heading2"], fontSize=11.5, spaceBefore=10, spaceAfter=4)
BODY = ParagraphStyle("Bodyx", parent=_styles["BodyText"], fontSize=10, leading=14, spaceAfter=6)
CAPTION = ParagraphStyle("Capx", parent=_styles["BodyText"], fontSize=8.5, leading=11,
                         textColor=colors.HexColor("#444444"), spaceBefore=2, spaceAfter=10)
TITLE = ParagraphStyle("Titlex", parent=_styles["Title"], fontSize=17, leading=22)

TABLE_STYLE = TableStyle([
    ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1f4e79")),
    ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
    ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
    ("FONTNAME", (0, 1), (-1, -1), "Helvetica"),
    ("FONTSIZE", (0, 0), (-1, -1), 8.5),
    ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#666666")),
    ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#eef2f7")]),
    ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
    ("LEFTPADDING", (0, 0), (-1, -1), 4),
    ("RIGHTPADDING", (0, 0), (-1, -1), 4),
])


def _footer(canvas, doc):
    """Draw the synthetic-data disclaimer and page number on every page."""
    canvas.saveState()
    canvas.setFont("Helvetica", 7)
    canvas.setFillColor(colors.HexColor("#777777"))
    canvas.drawString(20 * mm, 12 * mm, DISCLAIMER)
    canvas.drawRightString(190 * mm, 12 * mm, f"Seite {doc.page}")
    canvas.restoreState()


# --- figures (vector drawings; docling classifies them as pictures) ---------

def site_plan() -> Drawing:
    """Overview site plan: town, existing road, two bypass variants."""
    d = Drawing(440, 240)
    d.add(Rect(0, 0, 440, 240, fillColor=colors.HexColor("#f7fbf5"),
               strokeColor=colors.HexColor("#333333"), strokeWidth=1))
    # Town area
    d.add(Polygon([150, 90, 250, 80, 290, 120, 260, 170, 180, 175, 140, 140],
                  fillColor=colors.HexColor("#e8d8b0"), strokeColor=colors.HexColor("#8a7340")))
    d.add(String(185, 125, "Musterhausen", fontName="Helvetica-Bold", fontSize=11))
    # River
    d.add(PolyLine([40, 220, 90, 190, 120, 195, 160, 225],
                   strokeColor=colors.HexColor("#4a90d9"), strokeWidth=5))
    d.add(String(45, 226, "Mühlbach", fontSize=7, fillColor=colors.HexColor("#2a5a92")))
    # Existing B 999 through town
    d.add(PolyLine([10, 100, 150, 118, 260, 128, 430, 138],
                   strokeColor=colors.HexColor("#888888"), strokeWidth=3))
    d.add(String(20, 108, "B 999 (Bestand, Ortsdurchfahrt)", fontSize=7,
                 fillColor=colors.HexColor("#555555")))
    # Variant 1 (preferred): southern bypass
    d.add(PolyLine([10, 100, 90, 60, 200, 40, 320, 55, 400, 110, 430, 138],
                   strokeColor=colors.HexColor("#c0392b"), strokeWidth=3))
    d.add(String(180, 28, "Variante 1 (Vorzugsvariante, Südumfahrung)", fontSize=7,
                 fillColor=colors.HexColor("#c0392b")))
    # Variant 2: northern bypass (dashed)
    d.add(PolyLine([10, 100, 70, 160, 180, 205, 320, 195, 400, 160, 430, 138],
                   strokeColor=colors.HexColor("#27618f"), strokeWidth=2, strokeDashArray=[5, 3]))
    d.add(String(210, 210, "Variante 2 (Nordumfahrung)", fontSize=7,
                 fillColor=colors.HexColor("#27618f")))
    # Interchange markers
    for x, y in [(10, 100), (430, 138)]:
        d.add(Circle(x, y, 4, fillColor=colors.white, strokeColor=colors.black, strokeWidth=1.2))
    d.add(String(18, 88, "AS West", fontSize=7))
    d.add(String(392, 128, "AS Ost", fontSize=7))
    # North arrow
    d.add(Group(
        Polygon([415, 200, 421, 224, 409, 224], fillColor=colors.black),
        String(411, 190, "N", fontName="Helvetica-Bold", fontSize=9),
    ))
    # Scale hint
    d.add(Line(20, 20, 70, 20, strokeColor=colors.black, strokeWidth=1.5))
    d.add(String(24, 24, "1 km", fontSize=7))
    return d


def noise_chart() -> Drawing:
    """Grouped bar chart: rated noise levels (day) with/without barrier."""
    d = Drawing(440, 200)
    d.add(Rect(0, 0, 440, 200, fillColor=colors.white,
               strokeColor=colors.HexColor("#333333"), strokeWidth=1))
    x0, y0, h_max = 60, 40, 120  # plot origin and bar area height
    limit_db, top_db = 59, 75.0
    data = [  # (Immissionsort, without barrier dB(A), with barrier dB(A))
        ("IO 1 Bergstr. 12", 66.4, 56.1),
        ("IO 2 Schulweg 3", 63.8, 54.7),
        ("IO 3 Am Anger 8", 61.2, 52.9),
        ("IO 4 Feldrand 1", 58.5, 50.3),
    ]
    # Y axis + gridlines
    d.add(Line(x0, y0, x0, y0 + h_max + 10, strokeColor=colors.black))
    d.add(Line(x0, y0, x0 + 350, y0, strokeColor=colors.black))
    for db in (50, 55, 60, 65, 70):
        y = y0 + (db - 45) / (top_db - 45) * h_max
        d.add(Line(x0 - 3, y, x0 + 350, y, strokeColor=colors.HexColor("#dddddd")))
        d.add(String(x0 - 28, y - 3, f"{db} dB", fontSize=7))
    # Limit line (Grenzwert allgemeines Wohngebiet, Tag)
    y_lim = y0 + (limit_db - 45) / (top_db - 45) * h_max
    d.add(Line(x0, y_lim, x0 + 350, y_lim, strokeColor=colors.HexColor("#c0392b"),
               strokeWidth=1.4, strokeDashArray=[4, 3]))
    d.add(String(x0 + 255, y_lim + 4, f"Grenzwert {limit_db} dB(A) Tag", fontSize=7,
                 fillColor=colors.HexColor("#c0392b")))
    # Bars
    for i, (label, without, with_) in enumerate(data):
        gx = x0 + 25 + i * 82
        for j, (val, col) in enumerate([(without, "#8a8a8a"), (with_, "#2e7d32")]):
            bh = (val - 45) / (top_db - 45) * h_max
            d.add(Rect(gx + j * 24, y0, 20, bh, fillColor=colors.HexColor(col), strokeColor=None))
            d.add(String(gx + j * 24 - 1, y0 + bh + 3, f"{val:.0f}", fontSize=6.5))
        d.add(String(gx - 4, y0 - 12, label, fontSize=6.5))
    # Legend
    d.add(Rect(x0 + 8, y0 + h_max + 14, 10, 8, fillColor=colors.HexColor("#8a8a8a"), strokeColor=None))
    d.add(String(x0 + 22, y0 + h_max + 15, "ohne Lärmschutzwand", fontSize=7))
    d.add(Rect(x0 + 130, y0 + h_max + 14, 10, 8, fillColor=colors.HexColor("#2e7d32"), strokeColor=None))
    d.add(String(x0 + 144, y0 + h_max + 15, "mit Lärmschutzwand (H = 3,0 m)", fontSize=7))
    return d


# --- document 1: Erläuterungsbericht -----------------------------------------

def build_erlaeuterungsbericht(path: Path) -> None:
    doc = SimpleDocTemplate(str(path), pagesize=A4, topMargin=22 * mm, bottomMargin=22 * mm,
                            title="Erläuterungsbericht – " + PROJECT, author=APPLICANT)
    p = Paragraph
    story = [
        p("Planfeststellungsverfahren", H2),
        p("Erläuterungsbericht", TITLE),
        p("Unterlage 1", BODY),
        Spacer(1, 8),
        p(f"<b>Vorhaben:</b> {PROJECT}", BODY),
        p(f"<b>Vorhabenträger:</b> {APPLICANT}", BODY),
        p("<b>Planungsabschnitt:</b> Landesgrenze Musterland – Anschlussstelle Ost (Bau-km 0+000 bis 6+350)", BODY),
        p(f"<b>Stand:</b> {DATE}", BODY),
        Spacer(1, 14),

        p("1  Darstellung der Baumaßnahme", H1),
        p("Die Bundesstraße B 999 verläuft derzeit als Ortsdurchfahrt durch die zentrale " +
          "Ortslage von Musterhausen. Gegenstand des Verfahrens ist der Neubau einer rund " +
          "6,4 km langen Ortsumgehung südlich der Ortslage (B 999n) einschließlich zweier " +
          "planfreier Anschlussstellen (AS West, AS Ost), eines Brückenbauwerks über den " +
          "Mühlbach sowie straßenbegleitender Lärmschutz- und Entwässerungsanlagen. Die " +
          "bestehende Ortsdurchfahrt wird nach Verkehrsfreigabe zur Gemeindestraße " +
          "abgestuft.", BODY),

        p("2  Begründung des Vorhabens", H1),
        p("Die Ortsdurchfahrt Musterhausen ist mit der prognostizierten Verkehrsentwicklung " +
          "dauerhaft überlastet. Die Verkehrsuntersuchung 2024 weist folgende Belastungen " +
          "aus:", BODY),
        Table([
            ["Querschnitt", "DTV 2024 [Kfz/24h]", "Schwerverkehr 2024", "Prognose DTV 2040 [Kfz/24h]"],
            ["Ortsdurchfahrt Musterhausen", "18.400", "9,8 %", "21.700"],
            ["B 999 westlich Musterhausen", "15.200", "11,2 %", "17.900"],
            ["B 999 östlich Musterhausen", "16.100", "10,4 %", "19.300"],
            ["K 47 (Zubringer Gewerbegebiet)", "6.300", "14,6 %", "8.100"],
        ], colWidths=[62 * mm, 36 * mm, 34 * mm, 42 * mm], style=TABLE_STYLE, repeatRows=1),
        p("Tabelle 1: Verkehrsbelastung im Untersuchungsraum (Verkehrsuntersuchung Musterland 2024, synthetische Werte)", CAPTION),
        p("Neben der verkehrlichen Entlastung um prognostiziert rund 62 % in der Ortslage " +
          "verfolgt das Vorhaben die Ziele der Verbesserung der Verkehrssicherheit " +
          "(Unfallhäufungsstelle am Knoten Bergstraße), der Lärmentlastung von etwa 940 " +
          "Anwohnerinnen und Anwohnern sowie der Stärkung des regionalen Wirtschaftsraums " +
          "Beispielstadt–Musterhausen.", BODY),

        PageBreak(),
        p("3  Untersuchte Varianten", H1),
        p("Im Rahmen der Linienfindung wurden neben der Nullvariante eine Südumfahrung " +
          "(Variante 1) und eine Nordumfahrung (Variante 2) untersucht. Variante 2 quert " +
          "den Mühlbach zweifach, durchschneidet das Landschaftsschutzgebiet " +
          "„Mühlbachaue“ auf rund 1,9 km Länge und erfordert eine um etwa 27 % höhere " +
          "Investitionssumme. Variante 1 bündelt die Trasse mit einer bestehenden " +
          "110-kV-Freileitung, quert den Mühlbach nur einmal und weist die geringste " +
          "Neuversiegelung auf. Sie wird daher als Vorzugsvariante der Planfeststellung " +
          "zugrunde gelegt (Abbildung 1).", BODY),
        site_plan(),
        p("Abbildung 1: Übersichtslageplan mit Bestand (grau), Vorzugsvariante 1 (rot) und " +
          "verworfener Variante 2 (blau gestrichelt); unmaßstäbliche Prinzipskizze", CAPTION),

        p("4  Technische Gestaltung", H1),
        p("Die B 999n wird als einbahnige Bundesstraße mit dem Regelquerschnitt RQ 11 " +
          "geplant. Die wesentlichen technischen Kenndaten sind in Tabelle 2 " +
          "zusammengefasst.", BODY),
        Table([
            ["Kenngröße", "Wert"],
            ["Baulänge", "6.350 m"],
            ["Regelquerschnitt", "RQ 11 (Fahrbahnbreite 8,00 m)"],
            ["Entwurfsklasse / -geschwindigkeit", "EKL 3 / 90 km/h"],
            ["Anschlussstellen", "2 (AS West, AS Ost), planfrei"],
            ["Brückenbauwerke", "BW 1: Mühlbachbrücke, Stahlverbund, Stützweite 48 m"],
            ["Lärmschutz", "Lärmschutzwand H = 3,0 m, L = 780 m (Bau-km 2+100 bis 2+880)"],
            ["Regenrückhaltebecken", "2 Stück (RRB Süd 1.450 m³, RRB Ost 980 m³)"],
            ["Neuversiegelung", "ca. 9,6 ha"],
        ], colWidths=[64 * mm, 110 * mm], style=TABLE_STYLE, repeatRows=1),
        p("Tabelle 2: Technische Kenndaten der Vorzugsvariante (synthetische Werte)", CAPTION),

        p("5  Umweltverträglichkeit und naturschutzrechtliche Kompensation", H1),
        p("Die Auswirkungen des Vorhabens auf die Schutzgüter nach § 2 UVPG sind im " +
          "Umweltbericht (Unterlage 19.1) dargestellt. Unvermeidbare Eingriffe in Natur " +
          "und Landschaft werden durch Vermeidungs-, Ausgleichs- und vorgezogene " +
          "artenschutzrechtliche Maßnahmen (CEF) kompensiert; auf das Maßnahmenverzeichnis " +
          "in Unterlage 19.1, Kapitel 4 wird verwiesen.", BODY),
    ]
    doc.build(story, onFirstPage=_footer, onLaterPages=_footer)


# --- document 2: Umweltbericht (Kurzfassung) ---------------------------------

def build_umweltbericht(path: Path) -> None:
    doc = SimpleDocTemplate(str(path), pagesize=A4, topMargin=22 * mm, bottomMargin=22 * mm,
                            title="Umweltbericht (Kurzfassung) – " + PROJECT, author=APPLICANT)
    p = Paragraph
    story = [
        p("Planfeststellungsverfahren", H2),
        p("Umweltbericht – Kurzfassung", TITLE),
        p("Unterlage 19.1", BODY),
        Spacer(1, 8),
        p(f"<b>Vorhaben:</b> {PROJECT}", BODY),
        p(f"<b>Vorhabenträger:</b> {APPLICANT}", BODY),
        p(f"<b>Stand:</b> {DATE}", BODY),
        Spacer(1, 14),

        p("1  Untersuchungsraum und Methodik", H1),
        p("Der Untersuchungsraum umfasst einen Korridor von 500 m beidseits der " +
          "Vorzugstrasse zuzüglich der Ortslage Musterhausen. Die Bestandserfassung " +
          "erfolgte in den Kartierjahren 2024 und 2025 (Brutvögel, Fledermäuse, " +
          "Reptilien, Amphibien, Biotoptypen) nach den Standards des Landesamts für " +
          "Umwelt Musterland.", BODY),

        p("2  Schutzgut Tiere, Pflanzen und biologische Vielfalt", H1),
        p("Im Trassenumfeld wurden folgende planungsrelevante Arten nachgewiesen. Für " +
          "alle betroffenen Arten werden Vermeidungs- bzw. vorgezogene Ausgleichs­" +
          "maßnahmen (CEF) festgesetzt; erhebliche Beeinträchtigungen der lokalen " +
          "Populationen können damit ausgeschlossen werden.", BODY),
        Table([
            ["Art (deutsch)", "Art (wiss.)", "Status RL Land", "Betroffenheit", "Maßnahme"],
            ["Feldhamster", "Cricetus cricetus", "1 (vom Aussterben bedroht)", "Ackerflächen Bau-km 1+200–1+900", "CEF 1: Umsiedlung, Anlage Feldhamsterstreifen 2,4 ha"],
            ["Zauneidechse", "Lacerta agilis", "V (Vorwarnliste)", "Böschung Bestandstrasse AS West", "CEF 2: Habitatflächen 0,8 ha, Vergrämung/Umsiedlung"],
            ["Kammmolch", "Triturus cristatus", "2 (stark gefährdet)", "Kleingewässer nördlich Bau-km 4+300", "V 3: Amphibienleiteinrichtung, 2 Ersatzgewässer"],
            ["Feldlerche", "Alauda arvensis", "3 (gefährdet)", "4 Reviere im Offenland", "CEF 3: 6 Lerchenfenster/ha auf 12 ha Vertragsflächen"],
            ["Großer Abendsegler", "Nyctalus noctula", "3 (gefährdet)", "Leitstruktur Mühlbachaue (Querung)", "V 5: Irritationsschutzwände, Querungshilfe H = 4 m"],
        ], colWidths=[26 * mm, 30 * mm, 32 * mm, 42 * mm, 44 * mm], style=TABLE_STYLE, repeatRows=1),
        p("Tabelle 1: Planungsrelevante Arten und Konfliktbewältigung (synthetische Daten)", CAPTION),

        PageBreak(),
        p("3  Schutzgut Mensch – Lärm", H1),
        p("Für die schalltechnische Untersuchung wurden vier maßgebliche Immissionsorte " +
          "(IO) entlang der Trasse betrachtet. Mit der festgesetzten Lärmschutzwand " +
          "(H = 3,0 m, L = 780 m) werden die Immissionsgrenzwerte der 16. BImSchV für " +
          "allgemeine Wohngebiete an allen Immissionsorten eingehalten (Abbildung 1). In " +
          "der Ortsdurchfahrt Musterhausen sinkt der Beurteilungspegel nach " +
          "Verkehrsfreigabe um bis zu 7 dB(A).", BODY),
        noise_chart(),
        p("Abbildung 1: Beurteilungspegel Tag an den maßgeblichen Immissionsorten, " +
          "Prognose 2040 (synthetische Werte)", CAPTION),

        p("4  Maßnahmenübersicht", H1),
        Table([
            ["Nr.", "Typ", "Maßnahme", "Umfang"],
            ["V 1", "Vermeidung", "Bauzeitenregelung Gehölzrodung (Oktober–Februar)", "gesamte Trasse"],
            ["V 3", "Vermeidung", "Amphibienleiteinrichtung mit 4 Durchlässen", "Bau-km 4+100–4+600"],
            ["V 5", "Vermeidung", "Irritationsschutz- und Kollisionsschutzwände Fledermäuse", "Mühlbachquerung, 2 × 120 m"],
            ["A 2", "Ausgleich", "Entsiegelung und Rückbau Feldweg, Entwicklung Extensivgrünland", "1,7 ha"],
            ["A 4", "Ausgleich", "Anlage Gewässerrandstreifen Mühlbach mit Ufergehölzen", "2,3 km"],
            ["CEF 1", "CEF", "Feldhamster: Umsiedlung und Anlage von Feldhamsterstreifen", "2,4 ha"],
            ["CEF 3", "CEF", "Feldlerche: Lerchenfenster auf Vertragsflächen", "12 ha"],
        ], colWidths=[14 * mm, 24 * mm, 96 * mm, 40 * mm], style=TABLE_STYLE, repeatRows=1),
        p("Tabelle 2: Auszug aus dem Maßnahmenverzeichnis (synthetische Daten)", CAPTION),

        p("5  Zusammenfassende Bewertung", H1),
        p("Unter Berücksichtigung der festgesetzten Vermeidungs-, Ausgleichs- und " +
          "CEF-Maßnahmen verbleiben keine erheblichen nachteiligen Umweltauswirkungen im " +
          "Sinne des UVPG. Das Kompensationsdefizit wird vollständig innerhalb des " +
          "Naturraums ausgeglichen; ein Rückgriff auf das Ökokonto Musterland ist nicht " +
          "erforderlich.", BODY),
    ]
    doc.build(story, onFirstPage=_footer, onLaterPages=_footer)


# --- main --------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out-dir", default=".", help="output directory (default: cwd)")
    args = parser.parse_args()
    out = Path(args.out_dir).resolve()
    out.mkdir(parents=True, exist_ok=True)

    pdf1, pdf2 = out / PDF_1, out / PDF_2
    build_erlaeuterungsbericht(pdf1)
    build_umweltbericht(pdf2)

    zip_path = out / ZIP_NAME
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for pdf in (pdf1, pdf2):
            zf.write(pdf, pdf.name)

    for f in (pdf1, pdf2, zip_path):
        print(f"{f.stat().st_size:>8} bytes  {f.name}")


if __name__ == "__main__":
    main()
