# Azure DevOps Scripts

[![Build Status](https://dev.azure.com/ericvan/PipelineSamples/_apis/build/status%2Fagent%2Fget-agent-version?branchName=main&label=agent-version)](https://dev.azure.com/ericvan/PipelineSamples/_build/latest?definitionId=207&branchName=main)
[![Build Status](https://dev.azure.com/ericvan/PipelineSamples/_apis/build/status%2Ftasks%2Fdeprecated-task-usage?branchName=main&label=deprecated-tasks)](https://dev.azure.com/ericvan/PipelineSamples/_build/latest?definitionId=242&branchName=main)

This repository contains a few [PowerShell](https://github.com/PowerShell/PowerShell) scripts that use the [Azure DevOps REST APIs](https://learn.microsoft.com/rest/api/azure/devops) and [Azure DevOps CLI](https://learn.microsoft.com/azure/devops/cli/?view=azure-devops) (the [Azure CLI](https://github.com/Azure/azure-cli) with [Azure DevOps extension](https://github.com/Azure/azure-devops-cli-extension)) to interact with Azure DevOps:

## General

- Retrieve organization information (e.g. `id`) with  [get_organization.ps1](scripts/get_organization.ps1)
  
## Boards

- Validate whether backlog order honors dependencies with [validate_backlog_order.ps1](scripts/boards/validate_backlog_order.ps1)

## Pipelines

- Determine agent release for operating system & processor architecture with [get_agent_version.ps1](scripts/pipelines/get_agent_version.ps1)
- Install the agent using [install_agent.ps1](scripts/pipelines/install_agent.ps1) 
- List build & release tasks with [list_tasks.ps1](scripts/pipelines/list_tasks.ps1)
- List deprecated Pipelines tasks and their usage with [list_deprecated_tasks.ps1](scripts/pipelines/list_deprecated_tasks.ps1)  
This script is intended to be used from the [list-deprecated-tasks.yml](pipelines/list-deprecated-tasks.yml) pipeline

## Scripts in other repositories

- The [azure-identity-scripts](https://github.com/geekzter/azure-identity-scripts#azure-devops) repository contains various [scripts](https://github.com/geekzter/azure-identity-scripts/tree/main/scripts/azure-devops) that interact with Azure Active Directory e.g. to manage Service Connections
- The [azure-pipeline-examples](https://github.com/geekzter/azure-pipeline-examples) repository contains YAML that covers some scripting examples e.g. handling [scripting errors](https://github.com/geekzter/azure-pipeline-examples/blob/main/suppress-script-error.yml)