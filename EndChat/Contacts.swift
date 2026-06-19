import SwiftUI
import Foundation

struct Contact: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var nickname: String?
    var note: String?
    
    init(name: String, nickname: String? = nil, note: String? = nil) {
        self.name = name
        self.nickname = nickname
        self.note = note
    }
}

class ContactStore: ObservableObject {
    @Published var contacts: [Contact] = []
    
    func add(_ contact: Contact) {
        contacts.append(contact)
    }
    
    func remove(_ contact: Contact) {
        contacts.removeAll { $0.id == contact.id }
    }
}

struct ContactsView: View {
    @ObservedObject var store: ContactStore
    @State private var showingAdd = false
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.contacts) { contact in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.name).font(.headline)
                        if let nickname = contact.nickname, !nickname.isEmpty {
                            Text(nickname).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let note = contact.note, !note.isEmpty {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Contacts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddContactView(store: store)
            }
        }
    }
    
    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let contact = store.contacts[index]
            store.remove(contact)
        }
    }
}

struct AddContactView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ContactStore
    @State private var name = ""
    @State private var nickname = ""
    @State private var note = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Full name", text: $name)
                }
                Section("Nickname (optional)") {
                    TextField("Nickname", text: $nickname)
                }
                Section("Note (optional)") {
                    TextField("Note", text: $note)
                }
            }
            .navigationTitle("New Contact")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let contact = Contact(name: name, nickname: nickname.isEmpty ? nil : nickname, note: note.isEmpty ? nil : note)
                        store.add(contact)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

