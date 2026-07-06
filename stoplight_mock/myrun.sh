
 docker run --rm \
    -v $(pwd):/work \
    -v $(readlink -f mock/v40):/work/mock/v40:ro \
    -w /work \
    node:20-alpine \
    sh -c 'npm install --no-save js-yaml && node scripts/merge-specs.js'

  docker compose restart prism
