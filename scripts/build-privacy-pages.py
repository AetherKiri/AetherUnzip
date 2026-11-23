#!/usr/bin/env python3
"""Build the AetherUnzip landing page and privacy policy for GitHub Pages."""

import argparse
import re
import shutil
import subprocess
from html import escape
from pathlib import Path
from string import Template


ROOT = Path(__file__).resolve().parents[1]
SITE_URL = "https://aetherkiri.github.io/AetherUnzip/privacy/"
LANGUAGES = (
    ("en", "English", "", "Privacy Policy", "AetherUnzip", "Languages"),
    ("zh-Hans", "简体中文", "zh-cn/", "隐私政策", "以太解压", "语言"),
    ("ja", "日本語", "ja/", "プライバシーポリシー", "AetherUnzip", "言語"),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="Directory for the generated GitHub Pages site")
    output = parser.parse_args().output
    renderer = shutil.which("pandoc")
    if renderer is None:
        parser.error("Pandoc is required to render PRIVACY.md")

    template_dir = ROOT / "docs/privacy-site"
    template = Template((template_dir / "page.html").read_text(encoding="utf-8"))
    parts = re.split(r"^## ([^\n]+)\n", (ROOT / "PRIVACY.md").read_text(encoding="utf-8"), flags=re.M)
    policies = dict(zip(parts[1::2], parts[2::2], strict=True))
    if list(policies) != [language[1] for language in LANGUAGES]:
        parser.error("Expected one PRIVACY.md section for each language, in navigation order")

    privacy = output / "privacy"
    privacy.mkdir(parents=True, exist_ok=True)
    for language, heading, path, title, app_name, language_label in LANGUAGES:
        assets = "../" if path else "./"
        nav = []
        for alternate, name, alternate_path, *_ in LANGUAGES:
            current = ' aria-current="page"' if alternate == language else ""
            nav.append(f'<a href="{assets}{alternate_path}" lang="{alternate}" '
                       f'hreflang="{alternate}"{current}>{escape(name)}</a>')

        policy = subprocess.run([renderer, "--from=gfm", "--to=html5"], input=policies[heading],
                                text=True, encoding="utf-8", capture_output=True, check=True).stdout
        page = template.substitute(language=language, title=escape(title), app_name=escape(app_name),
                                   canonical=SITE_URL + path, assets=assets, language_label=language_label,
                                   language_links="\n        ".join(nav), policy=policy)
        directory = privacy / path
        directory.mkdir(exist_ok=True)
        (directory / "index.html").write_text(page, encoding="utf-8")

    shutil.copyfile(template_dir / "style.css", privacy / "style.css")
    shutil.copyfile(ROOT / "apps/AetherUnzip/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-Mac-128.png",
                    privacy / "icon.png")
    landing = output / "landing"
    landing.mkdir(exist_ok=True)
    landing_source = ROOT / "docs/landing-site"
    shutil.copyfile(landing_source / "index.html", output / "index.html")
    for asset in ("style.css", "gallery.js"):
        shutil.copyfile(landing_source / asset, landing / asset)
    for screenshot in ("smart-extraction.png", "archive-preview.png", "archive-identification.png",
                       "password-library.png"):
        shutil.copyfile(ROOT / "docs/images" / screenshot, landing / screenshot)
    (output / ".nojekyll").touch()


if __name__ == "__main__":
    main()
