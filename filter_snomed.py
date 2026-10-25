# filter_snomed.py   usage: python filter_snomed.py <folder with the ATHENA files> <output folder>
import sys, os

src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)

def filter_file(name, keep):
    kept = 0
    with open(os.path.join(src, name), encoding="utf-8") as fin, \
         open(os.path.join(dst, name), "w", encoding="utf-8", newline="") as fout:
        fout.write(fin.readline())                       # header
        for line in fin:
            cols = line.rstrip("\r\n").split("\t")
            if keep(cols):
                fout.write(line.rstrip("\r\n") + "\n")
                kept += 1
    print(name, "rows kept:", kept)

filter_file("CONCEPT.csv",              lambda c: len(c) > 3 and c[3] == "SNOMED")
filter_file("CONCEPT_RELATIONSHIP.csv", lambda c: len(c) > 2 and c[2] == "Maps to")