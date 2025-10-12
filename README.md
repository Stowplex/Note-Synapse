# Note Synapse

A local note-taking application with integrated AI features, built with Flutter and powered by Google's Gemini AI.

## Features

### Core Functionality
- **Local Note Storage**: All notes stored securely on device using SQLite
- **AI Integration**: Powered by Google's Gemini AI for intelligent note processing
- **Multi-format Support**: Text, voice, images, and file attachments
- **Task Management**: Convert notes to tasks with due dates and completion tracking
- **Relationship Mapping**: Link notes with semantic relationships
- **Tag System**: Organize notes with custom tags and filtering

### AI Features
- **Note Q&A**: Ask questions about your notes for comprehensive answers
- **Note Transformation**: Rewrite, reorganize, or modify notes using AI
- **New Note Creation**: Generate new notes based on prompts and context
- **Configurable Prompts**: Customize AI behavior for different use cases
- **Network Introspection**: Debug and modify AI requests in advanced settings

### Views
- **Notes View**: Main interface with search, multi-selection, and floating add button
- **Calendar View**: Visual calendar with task indicators and day-based filtering
- **Todo View**: Task management with completion percentage calculation and tag filtering
- **Timeline View**: Chronological note display with tag-based filtering
- **Settings**: API key management, data export, and AI interaction history

## Architecture

### Data Models
- **Note**: Core entity with title, content, type (note/task), tags, and sub-notes
- **SubNote**: Hierarchical note structure for detailed organization
- **Relationship**: Semantic connections between notes (answers, causality, related)
- **Tag**: Categorization system with usage tracking
- **AIInteraction**: Log of AI requests and responses with 10-day retention

### Database Schema
- **notes**: Main note storage with type, status, and metadata
- **subnotes**: Hierarchical note components
- **tags**: Tag definitions with usage statistics
- **note_tags**: Many-to-many note-tag relationships
- **attachments**: File attachment metadata
- **relationships**: Note relationship mappings
- **ai_interactions**: AI request/response logging

### AI Integration
- **Gemini API**: Google's latest AI model for text processing
- **Multi-modal Support**: Text, image, and voice input processing
- **Context Awareness**: AI operations consider note relationships and history
- **Prompt Engineering**: Structured prompts for consistent AI behavior

## Setup Instructions

### Prerequisites
1. Flutter SDK (3.9.2 or higher)
2. Google AI API key (free from [Google AI Studio](https://aistudio.google.com/app/apikey))

### Installation
1. Clone the repository
2. Run `flutter pub get` to install dependencies
3. Run `flutter packages pub run build_runner build` to generate JSON serialization code
4. Run `flutter run` to start the app

### First-Time Setup
1. Open the app
2. Enter your Google AI API key when prompted
3. The key is stored securely on your device

## Usage

### Creating Notes
1. **Text Notes**: Tap the + button and select "New Note"
2. **Voice Notes**: Select "New Voice" to record audio
3. **Image Notes**: Choose "New Picture" to capture or select images
4. **File Attachments**: Use "Attachment" to add documents

### AI Features
1. **Note Q&A**: Select one or more notes and use AI to answer questions
2. **Note Transformation**: Select a single note and ask AI to rewrite or reorganize it
3. **New Note Creation**: Use AI to generate new notes based on prompts and context

### Task Management
1. **Convert to Task**: Transform any note into a task with due dates
2. **Sub-tasks**: Add sub-notes to break down complex tasks
3. **Completion Tracking**: Monitor progress with percentage calculations
4. **Calendar View**: Visual task scheduling and deadline management

### Organization
1. **Tags**: Add custom tags to categorize notes
2. **Relationships**: Link related notes with semantic connections
3. **Search**: Find notes by title, content, or tags
4. **Filtering**: Use tags to filter notes in different views

## Development

### Project Structure
```
lib/
├── main.dart                 # App entry point
├── models/                   # Data models
│   ├── note.dart
│   ├── relationship.dart
│   ├── ai_interaction.dart
│   └── tag.dart
├── services/                 # Core services
│   ├── database_service.dart
│   ├── gemini_api_service.dart
│   └── secure_storage_service.dart
├── providers/                # State management
│   └── app_provider.dart
├── screens/                  # UI screens
│   ├── setup_screen.dart
│   ├── main_screen.dart
│   ├── notes_screen.dart
│   ├── calendar_screen.dart
│   ├── todo_screen.dart
│   ├── timeline_screen.dart
│   ├── note_detail_screen.dart
│   ├── ai_action_screen.dart
│   └── settings_screen.dart
└── widgets/                  # Reusable components
    └── note_card.dart
```

### Testing
- **Model Tests**: Core data structure validation
- **Database Tests**: SQLite operations with in-memory database
- **Widget Tests**: UI component testing
- **Integration Tests**: End-to-end functionality

Run tests with:
```bash
flutter test test/run_tests.dart
```

### Key Features Implementation

#### Database Service
- SQLite with proper schema design
- Relationship management with foreign keys
- Tag system with usage tracking
- AI interaction logging with expiration

#### AI Integration
- Gemini API integration with error handling
- Multi-modal input support (text, image, voice)
- Context-aware prompt engineering
- Response parsing and validation

#### UI/UX Design
- Material Design 3 with modern aesthetics
- Responsive layout for different screen sizes
- Intuitive navigation with bottom tabs
- Search and filtering capabilities

## Configuration

### AI Prompt Customization
The app allows customization of AI prompts for different functionalities:
- Multi-note Q&A prompts
- Note transformation prompts
- New note creation prompts

### Data Retention
- AI interactions are retained for 10 days
- Automatic cleanup of expired data
- Secure storage of API keys

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- Google AI Studio for providing the Gemini API
- Flutter team for the excellent framework
- SQLite for reliable local storage
- The open-source community for various packages used