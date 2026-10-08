"""Regenerate the Terminal Onboarding Perspective view from its markdown source.

    python tools/build_terminal_onboarding_view.py
    .\\scan.ps1

Source of truth: docs/terminal-onboarding.md. The view embeds a copy of it in an
ia.display.markdown component, so edit the markdown and re-run this -- never edit
the view's `source` by hand.

Page: /shop-floor/terminal-onboarding (MPP project), reached from the Terminal
Selector. Styling is the `.psc-pf-doc` block in the Core stylesheet.
"""
import io
import json
import os
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "docs", "terminal-onboarding.md")
VIEW_DIR = os.path.join(
    ROOT, "ignition", "projects", "MPP", "com.inductiveautomation.perspective",
    "views", "BlueRidge", "Views", "ShopFloor", "TerminalOnboarding")


def _source():
    with io.open(SOURCE, encoding="utf-8") as f:
        text = f.read().replace("\r\n", "\n")
    # The page has its own title bar, so drop the document's H1.
    lines = text.split("\n")
    if lines and lines[0].startswith("# "):
        lines = lines[1:]
    text = "\n".join(lines).strip() + "\n"
    # Perspective's markdown renderer has no task-list support.
    return text.replace("- [ ] ", u"- ☐ ")


def _view(source):
    return {
        "custom": {},
        "params": {},
        "props": {"defaultSize": {"width": 420, "height": 800}},
        "root": {
            "type": "ia.container.flex",
            "meta": {"name": "root"},
            "props": {
                "direction": "column",
                "style": {"height": "100%", "overflow": "hidden", "classes": "canvas"},
            },
            "children": [
                {
                    "type": "ia.container.flex",
                    "meta": {"name": "TopBar"},
                    "position": {"shrink": 0},
                    "props": {
                        "direction": "row",
                        "alignItems": "center",
                        "style": {
                            "gap": "10px",
                            "padding": "8px 12px",
                            "borderBottom": "1px solid var(--mpp-border-subtle)",
                        },
                    },
                    "children": [
                        {
                            "type": "ia.input.button",
                            "meta": {"name": "BackButton"},
                            "position": {"shrink": 0},
                            "props": {
                                "text": "Back",
                                "style": {"classes": "pf-btn pf-btn-secondary"},
                            },
                            "events": {
                                "component": {
                                    "onActionPerformed": {
                                        "type": "nav",
                                        "scope": "C",
                                        "config": {"page": "/shop-floor/terminal-selector"},
                                    }
                                }
                            },
                        },
                        {
                            "type": "ia.display.label",
                            "meta": {"name": "Title"},
                            "position": {"grow": 1, "basis": "0"},
                            "props": {
                                "text": "Terminal Onboarding",
                                "style": {"fontSize": "18px", "fontWeight": 700, "color": "var(--mpp-text-primary)"},
                            },
                        },
                    ],
                },
                {
                    "type": "ia.container.flex",
                    "meta": {"name": "Body"},
                    "position": {"grow": 1, "basis": "0"},
                    "props": {
                        "direction": "column",
                        "alignItems": "center",
                        "style": {"overflowY": "auto", "overflowX": "hidden"},
                    },
                    "children": [
                        {
                            "type": "ia.display.markdown",
                            "meta": {"name": "Guide"},
                            "position": {"shrink": 0},
                            "props": {
                                "source": source,
                                "style": {
                                    "classes": "pf-doc",
                                    "width": "100%",
                                    "maxWidth": "760px",
                                    "padding": "4px 16px 48px 16px",
                                    "overflow": "visible",
                                },
                            },
                        }
                    ],
                },
            ],
        },
    }


def main():
    if not os.path.isdir(VIEW_DIR):
        os.makedirs(VIEW_DIR)
    with io.open(os.path.join(VIEW_DIR, "view.json"), "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(_view(_source()), indent=2, ensure_ascii=False))
    resource = {
        "scope": "G",
        "version": 1,
        "restricted": False,
        "overridable": True,
        "files": ["view.json"],
        "attributes": {
            "lastModification": {
                "actor": "claude",
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
        },
    }
    with io.open(os.path.join(VIEW_DIR, "resource.json"), "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(resource, indent=2))
    print("wrote %s" % VIEW_DIR)


if __name__ == "__main__":
    main()
