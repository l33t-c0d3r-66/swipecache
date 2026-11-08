/// Web and other platforms without `dart:io`: nothing can be measured.
(int? ram, int cores) probeDevice() => (null, 0);
