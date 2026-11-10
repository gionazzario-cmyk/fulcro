import SwiftUI
import AppKit

struct CronologiaView: View {
    @ObservedObject var core: JarvisCore
    /// Chiama JarvisCore per riaprire il filo, e la finestra ci cambia anche la schermata.
    var riapriChat: (String) -> Void = { _ in }
    @State private var query = ""
    @State private var entries: [Entry] = []
    @State private var selectedEntryId: Date? = nil

    private var filteredGroups: [(dateString: String, items: [Entry])] {
        let list: [Entry]
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            list = entries
        } else {
            let q = query.lowercased()
            list = entries.filter { $0.text.lowercased().contains(q) || $0.role.lowercased().contains(q) }
        }

        let calendar = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "it_IT")
        dayFormatter.dateFormat = "EEEE d MMMM yyyy"

        let grouped = Dictionary(grouping: list) { entry -> String in
            if calendar.isDateInToday(entry.ts) {
                return "Oggi"
            } else if calendar.isDateInYesterday(entry.ts) {
                return "Ieri"
            } else {
                return dayFormatter.string(from: entry.ts).capitalized
            }
        }

        // Ordina i giorni dal più recente al più vecchio
        return grouped.map { (dateString: $0.key, items: $0.value) }
            .sorted { (g1, g2) -> Bool in
                let d1 = g1.items.first?.ts ?? Date.distantPast
                let d2 = g2.items.first?.ts ?? Date.distantPast
                return d1 > d2
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(Color.white.opacity(0.08))

            if entries.isEmpty {
                vuotoView
            } else {
                listaEntries
            }
        }
        .background(pannelloScuro)
        .onAppear {
            carica()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
                TextField("Cerca nella cronologia delle chat…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1)))

            Button {
                carica()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(8)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Ricarica storico")

            Text("\(entries.count) messaggi")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(16)
    }

    private var listaEntries: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(filteredGroups, id: \.dateString) { gruppo in
                        VStack(alignment: .leading, spacing: 10) {
                            // Intestazione data
                            HStack(spacing: 8) {
                                Text(gruppo.dateString)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.3))
                                Rectangle()
                                    .fill(Color.white.opacity(0.08))
                                    .frame(height: 1)
                            }
                            .padding(.top, 6)

                            ForEach(gruppo.items, id: \.ts) { item in
                                cronologiaItem(item)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
    }

    private func cronologiaItem(_ item: Entry) -> some View {
        let isUser = item.role == "tu" || item.role == "user"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let orario = timeFormatter.string(from: item.ts)

        return HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(isUser ? AnyShapeStyle(jarvisGrad) : AnyShapeStyle(Color.white.opacity(0.12)))
                    .frame(width: 24, height: 24)
                Image(systemName: isUser ? "person.fill" : "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(isUser ? .white : Color(red: 1, green: 0.35, blue: 0.3))
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(isUser ? "Tu" : "\(Marca.nome)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isUser ? Olografico.cianoTenue : .white.opacity(0.85))

                    Text(orario)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))

                    if !item.source.isEmpty && item.source != "chat" {
                        Text(item.source)
                            .font(.system(size: 9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                }

                Text(item.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isUser ? Olografico.ciano.opacity(0.09) : Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isUser ? Olografico.ciano.opacity(0.16) : Color.white.opacity(0.06)))
        }
        // Un clic riporta alla chat di quel messaggio, cosi' cronologia e lista chat non
        // sono due mondi staccati.
        .contentShape(Rectangle())
        .onTapGesture {
            if let s = item.session, !s.isEmpty { riapriChat(s) }
        }
        .overlay(alignment: .trailing) {
            if item.session != nil {
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.22))
                    .padding(8)
                    .help("Riapri questa chat")
            }
        }
    }

    private var vuotoView: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 38))
                .foregroundStyle(.white.opacity(0.2))
            Text("Nessun messaggio trovato")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func carica() {
        entries = Store.shared.reload()
    }
}
