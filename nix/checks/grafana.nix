# The pinned Grafana provisions the dashboards of a rendered payload: grafana.py runs the image's own binary on the
# files the manifest gives the pod, in the build sandbox, against sqlite
{
  pkgs,
  image,
  payload,
}:
pkgs.runCommand "check-grafana"
  {
    nativeBuildInputs = [
      pkgs.gnutar
      pkgs.jq
      (pkgs.python3.withPackages (p: [ p.pyyaml ]))
    ];
  }
  ''
    mkdir image root work
    tar -xf ${image} -C image
    for layer in $(jq -r '.[0].Layers[]' image/manifest.json); do
      tar -xf "image/$layer" -C root --no-same-owner --no-same-permissions --exclude='dev/*'
    done
    python3 ${./grafana.py} "$PWD/root" ${payload}/grafana.yaml "$PWD/work"
    touch $out
  ''
