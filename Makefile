.PHONY: build debug run clean

build:
	./scripts/build.sh release

debug:
	./scripts/build.sh debug

run: build
	-pkill -x AgentNotch
	open "$$HOME/Library/Developer/AgentNotch/AgentNotch.app"

clean:
	rm -rf .build build "$$HOME/Library/Developer/AgentNotch"
