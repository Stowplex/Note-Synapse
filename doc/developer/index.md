# Contributing to Note Synapse

Welcome! Note Synapse is a local-first, AI-native application built with Flutter and Rust.

## Getting Started
If you are looking to build **User Apps** (Action tools, Dashboards) using HTML/JS, please see the [Power User / Vibe Coding](../power_user/overview.md) section.

If you are looking to modify the **Core App** (Dart/Rust), you are in the right place.

## Architecture
See [Architecture](architecture.md) for a high-level overview of the system, including:
*   Local-first database (SQLite)
*   HTTP/3 Networking (Rust bridge)
*   Agentic AI Services

## Setting up the Environment
1.  **Flutter**: Install the latest stable version of Flutter.
2.  **Rust**: Install Rust via rustup (needed for `rhttp` and native bridges).
3.  **Supabase**: (Optional) For sync features, we use a local Supabase instance for testing.
