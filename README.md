# VSS Workshop — 2× RTX PRO 6000 on AWS Brev

This repository is a focused workshop deployment of NVIDIA Video Search and Summarization (VSS) 3.2.1. It runs the Base visual-Q&A and report-generation flow with one dedicated GPU per model:

| GPU | Model |
| --- | --- |
| 0 | NVIDIA Nemotron Nano 9B v2 |
| 1 | Cosmos3 Nano Reasoner |

## Start here

Open and run [00_START_HERE_VSS_WORKSHOP.ipynb](00_START_HERE_VSS_WORKSHOP.ipynb) from the repository root in Jupyter. It explains every workshop step, asks only for your NGC API key, checks the instance, deploys VSS, and guides you through uploading an MP4, visual Q&A, and report generation.

The notebook is designed for an AWS Brev VM with exactly two RTX PRO 6000 GPUs. Bring a short MP4 and an [NGC API key](https://org.ngc.nvidia.com/setup/api-keys); your key is stored only in a private file on the VM, never in this repository.

## If you need the command line

The notebook uses the single supported deployment command:

```bash
workshop/scripts/deploy_vss_base.sh check
NGC_API_KEY='your-key' workshop/scripts/deploy_vss_base.sh deploy
workshop/scripts/deploy_vss_base.sh status
workshop/scripts/deploy_vss_base.sh stop
```

`stop` preserves uploaded videos, model caches, and Docker volumes. It does not delete data.

The runtime assets needed by this workshop are under `workshop/runtime/`. They are intentionally not a general-purpose VSS deployment kit.

## Updating the workshop interface

The deployed **VSS AI Advisor Workshop** interface is repository-owned rather
than a prebuilt vendor screen. Its small, editable source lives in
`workshop/runtime/services/ui/workshop/`: change `config.js` for the title,
`app.css` for the presentation, or `app.js` for the attendee workflow. Pull
the update and run `deploy` again to apply it on a Brev VM.

For the underlying platform documentation, see the [VSS Brev guide](https://docs.nvidia.com/vss/latest/cloud-brev.html) and [VSS prerequisites](https://docs.nvidia.com/vss/latest/prerequisites.html).
