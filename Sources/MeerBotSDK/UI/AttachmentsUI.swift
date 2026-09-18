// MeerBot iOS SDK — показ вложений и выбор файлов.
//
// Показ (`AttachmentContentView`/`AttachmentChip`) кроссплатформенный — `MessageBubbleView`
// компилируется и на macOS-хосте CI. Инлайновая картинка (`AttachmentImageView`) и выбор
// файла (PHPicker/UIDocumentPicker) — только под UIKit: продуктовая площадка iOS.

import SwiftUI

/// Загрузчик байтов вложения по (messageId, mediaId). Реализация — `ChatController.loadMedia`.
typealias MediaLoader = (Int, String) async throws -> Data

/// Человекочитаемый размер файла.
func mbFormatBytes(_ size: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(0, size)), countStyle: .file)
}

/// Иконка вида вложения для плашки.
func mbAttachmentIcon(kind: String) -> String {
    switch kind {
    case "image": return "photo"
    case "video": return "video"
    case "audio": return "waveform"
    default: return "doc"
    }
}

/// Одно вложение сообщения. Картинку с сервера рисует инлайн (только UIKit и когда у неё уже
/// есть `mediaId` и у сообщения — серверный id); всё остальное и локальные превью — плашкой.
struct AttachmentContentView: View {
    let messageId: Int?
    let attachment: Attachment
    let tint: Color
    let load: MediaLoader

    private var canRenderRemoteImage: Bool {
        attachment.kind == "image" && !attachment.mediaId.isEmpty && messageId != nil
    }

    var body: some View {
        #if canImport(UIKit)
        if canRenderRemoteImage, let messageId {
            AttachmentImageView(messageId: messageId, attachment: attachment, tint: tint, load: load)
        } else {
            AttachmentChip(attachment: attachment, tint: tint)
        }
        #else
        AttachmentChip(attachment: attachment, tint: tint)
        #endif
    }
}

/// Плашка «иконка + имя + размер». Фолбэк для файлов, локальных превью и не загрузившихся
/// картинок — вместо краша или пустоты.
struct AttachmentChip: View {
    let attachment: Attachment
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: mbAttachmentIcon(kind: attachment.kind))
                .font(.system(size: 20))
                .foregroundColor(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName ?? defaultName)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(mbFormatBytes(attachment.size))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: 240, alignment: .leading)
        .background(Color.mbSurfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var defaultName: String {
        switch attachment.kind {
        case "image": return "Изображение"
        case "video": return "Видео"
        case "audio": return "Аудио"
        default: return "Файл"
        }
    }
}

#if canImport(UIKit)
import UIKit

/// Кэш загруженных картинок: ключ — `messageId/mediaId`. Перерисовки ленты (стриминг, тики
/// таймера) не должны заново дёргать сеть за той же картинкой.
enum MBMediaImageCache {
    static let shared = NSCache<NSString, UIImage>()
}

/// Инлайновая картинка вложения: качается авторизованным запросом (через `load`), кладётся в
/// кэш. Не загрузилась — плашка, а не пустота и не краш.
struct AttachmentImageView: View {
    let messageId: Int
    let attachment: Attachment
    let tint: Color
    let load: MediaLoader

    @State private var image: UIImage?
    @State private var failed = false

    private var cacheKey: NSString { "\(messageId)/\(attachment.mediaId)" as NSString }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if failed {
                AttachmentChip(attachment: attachment, tint: tint)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.mbSurfaceSecondary)
                    ProgressView()
                }
                .frame(width: 160, height: 120)
            }
        }
        .task(id: cacheKey) { await loadImage() }
    }

    private func loadImage() async {
        if let cached = MBMediaImageCache.shared.object(forKey: cacheKey) {
            image = cached
            return
        }
        do {
            let data = try await load(messageId, attachment.mediaId)
            if let img = UIImage(data: data) {
                MBMediaImageCache.shared.setObject(img, forKey: cacheKey)
                image = img
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}

import PhotosUI
import UniformTypeIdentifiers

/// Экран выбора вложения, показываемый композером.
enum AttachmentPickerKind: Identifiable {
    case media   // фото и видео (PHPicker)
    case file    // произвольный файл (UIDocumentPicker)
    var id: Int { self == .media ? 0 : 1 }
}

/// Фото и видео из библиотеки. Разрешения на выбор не требуется — PHPicker работает
/// вне процесса приложения.
struct MediaPicker: UIViewControllerRepresentable {
    /// Сколько ещё можно добавить (≤10 суммарно).
    let remaining: Int
    let onPicked: ([OutgoingAttachment]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = max(1, remaining)
        config.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([OutgoingAttachment]) -> Void
        init(onPicked: @escaping ([OutgoingAttachment]) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { onPicked([]); return }
            let group = DispatchGroup()
            let lock = NSLock()
            var collected: [OutgoingAttachment] = []
            for result in results {
                group.enter()
                Self.load(result.itemProvider) { attachment in
                    if let attachment {
                        lock.lock(); collected.append(attachment); lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { [onPicked] in onPicked(collected) }
        }

        /// Достаём из выбранного Data + имя + mime. `loadFileRepresentation` даёт временный
        /// файл с настоящим расширением — по нему и берём mime.
        private static func load(
            _ provider: NSItemProvider,
            completion: @escaping (OutgoingAttachment?) -> Void
        ) {
            let typeId = provider.registeredTypeIdentifiers.first
                ?? UTType.data.identifier
            provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else {
                    completion(nil)
                    return
                }
                let ext = url.pathExtension
                let base = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                let name = ext.isEmpty ? base : "\(base).\(ext)"
                let mime = UTType(typeId)?.preferredMIMEType
                    ?? UTType(filenameExtension: ext)?.preferredMIMEType
                    ?? "application/octet-stream"
                completion(OutgoingAttachment(data: data, fileName: name, mime: mime))
            }
        }
    }
}

/// Произвольные файлы. `asCopy: true` — система кладёт копию в песочницу, доступную сразу.
struct DocumentPicker: UIViewControllerRepresentable {
    let onPicked: ([OutgoingAttachment]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: ([OutgoingAttachment]) -> Void
        init(onPicked: @escaping ([OutgoingAttachment]) -> Void) { self.onPicked = onPicked }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            let items: [OutgoingAttachment] = urls.compactMap { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return nil }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
                return OutgoingAttachment(data: data, fileName: url.lastPathComponent, mime: mime)
            }
            onPicked(items)
        }

        // Отмена — no-op: ничего не выбрали, текст композера не трогаем.
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPicked([])
        }
    }
}
#endif
