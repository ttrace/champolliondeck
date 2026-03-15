# Champollion Deck

Champollion Deck is a local translation app prototype for Apple platforms.

Current focus:
- macOS-first implementation with Swift + SwiftUI
- deterministic preprocessing before translation
- engine-swappable design (Foundation Models / Core ML backends)

## Project Structure

- `Sources/App/`: app entry point
- `Sources/Features/Translation/`: translation UI and view model
- `Sources/Domain/`: core models and protocols
- `Sources/Engines/Preprocess/`: deterministic preprocessing
- `Sources/Engines/Translation/`: translation engine stubs
- `Sources/Services/`: orchestration and engine policy
- `Tests/`: unit tests

## Build

```bash
swift build
```

## Test

```bash
swift test
```

## License

This project is licensed under the MIT License. See `LICENSE`.
