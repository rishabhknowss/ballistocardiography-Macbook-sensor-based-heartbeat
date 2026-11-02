bin/heartbeat: Sources/heartbeat.swift
	@mkdir -p bin
	swiftc -O Sources/heartbeat.swift -o bin/heartbeat

bin/harmonium: Sources/harmonium.swift
	@mkdir -p bin
	swiftc -O Sources/harmonium.swift -o bin/harmonium

run: bin/heartbeat
	./bin/heartbeat

harmonium: bin/harmonium
	./bin/harmonium

clean:
	rm -rf bin

.PHONY: run harmonium clean
