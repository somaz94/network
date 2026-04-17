## Installing the Chart
Before you can install the chart you will need to add the external-dns repo to .

```bash
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
```

After you've installed the repo you can install the chart.

```bash
helm upgrade --install external-dns external-dns/external-dns --version 1.18.0
```
