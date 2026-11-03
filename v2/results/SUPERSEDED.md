# Superseded: `synth_v2.txt` area numbers

`synth_v2.txt` in this directory is a historical report. Its summary section
records **497,927.19 um2 flat / 33,936 cells / 55.18 % of row area**. That
number is not reproducible and is superseded.

The flat script printed inside the log, run on the identical 11 `.v` sha256
values listed in its own environment section, with the same yosys 0.33 and the
same IHP liberty, produces **519,233.80 um2 flat / 36,343 cells = 57.54 % of
row area** (95.90 % of the 60 % budget, 22,216.40 um2 spare). Two independent
runs agree exactly.

Sign-off evidence: `results/synth_v2_root.txt` — `Chip area for module
'\tt_um_proteus': 519233.803200` (line 47230), `Number of cells: 36343`
(line 47202), hierarchical `538016.131800` (line 19254). The reconciliation
and the unexplainable +21,306.61 um2 (+4.28 %) difference are recorded in
`results/final_evidence.md` §3 and `docs/verification.md` §2.9.

Do not cite the 497,927.19 / 33,936 / 55.18 % figures as the shipped design.
