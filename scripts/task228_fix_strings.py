#!/usr/bin/env python3
"""Task228: repair the unescaped inner quotes in ame227.deps.message
(en / ja / zh-Hans / zh-Hant) that made the WHOLE table unparseable.

Forensics (byte-level, repr-verified):
  broken : "ame227.deps.message" = ""%@" depends on ...";
  correct: "ame227.deps.message" = "\"%@" depends on ...";   (zh-CN shipped OK)

CFPropertyList's old-style parser rejects the entire .strings table on one
malformed entry, so all four tables went dead at once; the localize()
fallback chain (selected -> en -> zh-Hans) had no surviving hop and the
whole UI showed raw key names in every language. This is the SECOND
occurrence of the exact bug class (Task191 shipped the same defect in
en.lproj once before) -- hence the CI gate added alongside this script.
"""
import sys

FILES = ["en", "ja", "zh-Hans", "zh-Hant"]
BROKEN_FRAGMENT = '""%@"'          # value-open quote + unescaped inner pair
FIXED_FRAGMENT = '"\\"%@\\"'        # value-open quote + escaped inner pair


def main():
    failed = False
    for lang in FILES:
        path = "Natives/resources/%s.lproj/Localizable.strings" % lang
        with open(path, "r", encoding="utf-8", newline="") as f:
            lines = f.readlines()

        repaired = 0
        already = 0
        for idx, line in enumerate(lines):
            if '"ame227.deps.message"' not in line:
                continue
            if BROKEN_FRAGMENT in line:
                lines[idx] = line.replace(BROKEN_FRAGMENT, FIXED_FRAGMENT)
                repaired += 1
            elif FIXED_FRAGMENT in line:
                already += 1
            else:
                print("%s: UNEXPECTED line content: %r" % (lang, line[:120]))
                failed = True

        if repaired == 1:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.writelines(lines)
            print("%s: repaired 1 line" % lang)
        elif repaired > 1:
            print("%s: MULTIPLE broken lines (%d) -- NOT writing" % (lang, repaired))
            failed = True
        elif already == 1 and not failed:
            print("%s: already fixed (idempotent skip)" % lang)
        elif already == 0 and repaired == 0:
            print("%s: target line not found at all" % lang)
            failed = True

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
