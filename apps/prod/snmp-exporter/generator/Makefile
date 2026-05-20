OUT=output/snmp.yaml
PWD=$(shell pwd)

.PHONY: generate
generate:
	docker run --rm \
		-v $(PWD)/mibs:/opt/mibs \
		-v $(PWD)/output:/opt/output \
		-v $(PWD)/generator.yaml:/opt/generator.yaml \
		prom/snmp-generator:latest generate \
		-g /opt/generator.yaml \
		-m /opt/mibs/shared \
		-m /opt/mibs/openbsd \
		-m /opt/mibs/truenas \
		-m /opt/mibs/zyxel \
		-o /opt/output/snmp.yaml \
		--no-fail-on-parse-errors \
		--log.level=debug

.PHONY: clean
clean:
	rm -f $(OUT)

.PHONY: clean-gen
clean-gen: clean generate

default: clean-gen
