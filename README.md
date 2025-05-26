# Nucleus Enterprise Taskbot Agent

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
<!-- Add other relevant badges: build status, version, etc. -->
<!-- e.g., [![GitHub version](https://badge.fury.io/gh/nucleusenterpriseai%2Fnucleus-taskbot-agent.svg)](https://badge.fury.io/gh/nucleusenterpriseai%2Fnucleus-taskbot-agent) -->

Welcome to the **Nucleus Enterprise Taskbot Agent** repository! We are excited to open-source this powerful Python-based framework designed to help developers build and deploy sophisticated multi-agent systems.

## 🎯 Goal and Purpose

The primary goal of the Nucleus Taskbot Agent is to empower developers to create **"CoMpUse" (Computer Use) agents** – intelligent agents capable of performing a wide array of computer-based tasks on Linux environments. These agents can understand complex instructions and interact with systems by leveraging:

*   **Multi-Agent Architecture:** Design and orchestrate multiple specialized agents working in concert.
*   **Customizable Tools:** Easily integrate and develop custom tools that agents can utilize to interact with various systems, APIs, and data sources.
*   **Advanced Perception:** Inspired by capabilities like Microsoft's OmniParse, enabling agents to better understand and interact with digital interfaces and content.
*   **Flexible LLM Integration:** Seamlessly connect with both open-source and proprietary Large Language Models (LLMs) as defined by the user, allowing for tailored intelligence and reasoning capabilities.
*   **On-Premise Deployment:** Designed for easy installation and operation within your on-premise environment, ensuring data control and security.
*   **Offline Capabilities:** Built with considerations for scenarios requiring offline operation (depending on chosen LLMs and tools).

This framework provides the building blocks for automating complex workflows, enhancing productivity, and creating innovative AI-driven solutions that can operate directly on computer systems.

## ✨ Features

*   **Multi-Agent Systems:** Support for developing applications with multiple collaborating agents.
*   **Tool Integration:** Extensible system for adding custom tools that agents can use to perform actions.
*   **LLM Agnostic:** Bring your own LLM – connect to OpenAI, Anthropic, Cohere, or self-hosted open-source models.
*   **Easy On-Premise Installation:** A simple one-liner shell command to deploy the entire Taskbot stack (including frontend, backend, and necessary services) using Docker.
*   **Self-Contained Deployment:** Includes a management portal (Next.js frontend) and robust backend services (Java-based).


## 🚀 Quick Start: One-Liner Installation

You can install the entire Nucleus Taskbot Agent stack on your on-premise Linux VM (Ubuntu/Debian recommended) with a single command. This will set up Docker, download the necessary configurations, and start all services.

**Prerequisites:**
*   A Linux VM (Ubuntu/Debian-like) with internet access.
*   `curl` installed.
*   `sudo` privileges.

**Installation Command:**

```bash
curl -fsSL https://raw.githubusercontent.com/nucleusenterpriseai/nucleus-taskbot-agent/main/install_taskbot.sh -o install_taskbot.sh && chmod +x install_taskbot.sh && sudo ./install_taskbot.sh
```