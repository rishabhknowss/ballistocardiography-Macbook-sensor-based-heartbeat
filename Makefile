bin/heartbeat: Sources/heartbeat.swift
	@mkdir -p bin
	swiftc -O Sources/heartbeat.swift -o bin/heartbeat

bin/sax: Sources/sax.swift
	@mkdir -p bin
	swiftc -O Sources/sax.swift -o bin/sax

run: bin/heartbeat
	./bin/heartbeat

sax: bin/sax
	./bin/sax

clean:
	rm -rf bin

.PHONY: run sax clean
