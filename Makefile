# Makefile

RESOURCE_GROUP ?= my-resource-group

.PHONY: run clean

run:
	./run.sh

clean:
	az group delete -n $(RESOURCE_GROUP) --yes --no-wait
	rm -f aks-labs-gitops.yaml \
	      aks-*.config \
	      aso-credentials.yaml \
	      bootstrap-addons.yaml \
	      capi-operator-values.yaml \
	      identity.yaml
