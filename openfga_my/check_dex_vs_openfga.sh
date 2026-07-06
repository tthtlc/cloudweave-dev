echo "=== container start times ==="; for c in openfga dex lldap; do printf "%-10s " "$c"; docker inspect $c --format '{{.State.StartedAt}}' 2>/dev/null; done
echo; echo "=== Dex key storage / config ==="; docker inspect dex --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' 2>/dev/null
echo "=== full dex storage/key config ==="; docker exec dex sh -c 'cat /etc/dex/config.yaml' 2>&1 | grep -iE -A3 'storage:|web:|signing|keys|connectors' | head -40
echo; echo "=== dex storage file in container (sqlite?) ==="; docker exec dex sh -c 'ls -la /var/dex 2>/dev/null; ls -la /dex 2>/dev/null' 2>&1 | head
