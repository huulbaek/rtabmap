//
//  PhotoMetadataEditor.swift
//  RTABMapApp
//
//  Programmatic modal for editing a PhotoSidecar's user metadata.
//

import UIKit

protocol PhotoMetadataEditorDelegate: AnyObject {
    func editor(_ editor: PhotoMetadataEditor, didSave sidecar: PhotoSidecar, at jpegURL: URL)
    func editor(_ editor: PhotoMetadataEditor, didDelete jpegURL: URL)
}

final class PhotoMetadataEditor: UIViewController, UITableViewDataSource, UITableViewDelegate {

    weak var delegate: PhotoMetadataEditorDelegate?

    private let jpegURL: URL
    private var sidecar: PhotoSidecar

    private let thumbnailView = UIImageView()
    private let labelField = UITextField()
    private let noteView = UITextView()
    private let tagsField = UITextField()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private static let suggestedKeys = [
        "dimensions.length_mm", "dimensions.width_mm", "dimensions.height_mm",
        "condition",
        "origin.building", "origin.year",
        "material",
        "contamination.pfas", "contamination.asbestos",
        "certification"
    ]

    init(jpegURL: URL, sidecar: PhotoSidecar) {
        self.jpegURL = jpegURL
        self.sidecar = sidecar
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Delete", style: .plain, target: self, action: #selector(deleteTapped))
        navigationItem.leftBarButtonItem?.tintColor = .systemRed
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        navigationItem.title = "Photo metadata"

        thumbnailView.contentMode = .scaleAspectFit
        thumbnailView.clipsToBounds = true
        thumbnailView.image = UIImage(contentsOfFile: jpegURL.path)

        labelField.placeholder = "Label (optional)"
        labelField.borderStyle = .roundedRect
        labelField.text = sidecar.user.label

        noteView.layer.borderColor = UIColor.separator.cgColor
        noteView.layer.borderWidth = 1
        noteView.layer.cornerRadius = 6
        noteView.font = .preferredFont(forTextStyle: .body)
        noteView.text = sidecar.user.note

        tagsField.placeholder = "Tags (comma-separated)"
        tagsField.borderStyle = .roundedRect
        tagsField.text = sidecar.user.tags.joined(separator: ", ")

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "prop")

        let stack = UIStackView(arrangedSubviews: [thumbnailView, labelField, noteView, tagsField, tableView])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            thumbnailView.heightAnchor.constraint(equalToConstant: 200),
            noteView.heightAnchor.constraint(equalToConstant: 80),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    // MARK: - Actions

    @objc private func doneTapped() {
        sidecar.user.label = labelField.text ?? ""
        sidecar.user.note = noteView.text ?? ""
        sidecar.user.tags = (tagsField.text ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            try ManualPhotoStore.shared.updateSidecar(sidecar, for: jpegURL)
            delegate?.editor(self, didSave: sidecar, at: jpegURL)
            dismiss(animated: true)
        } catch {
            let alert = UIAlertController(title: "Save failed", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(.init(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    @objc private func deleteTapped() {
        let alert = UIAlertController(title: "Delete photo?", message: nil, preferredStyle: .alert)
        alert.addAction(.init(title: "Cancel", style: .cancel))
        alert.addAction(.init(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            ManualPhotoStore.shared.deletePhoto(jpegURL: self.jpegURL)
            self.delegate?.editor(self, didDelete: self.jpegURL)
            self.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tv: UITableView, titleForHeaderInSection s: Int) -> String? { "Properties" }

    func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int {
        sidecar.user.properties.count + 1 // +1 for the "Add property" row
    }

    func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "prop", for: ip)
        cell.accessoryType = .none
        cell.selectionStyle = .default
        if ip.row < sidecar.user.properties.count {
            let p = sidecar.user.properties[ip.row]
            let unit = p.unit.map { " \($0)" } ?? ""
            cell.textLabel?.text = "\(p.key): \(p.value)\(unit)"
            cell.textLabel?.textColor = .label
        } else {
            cell.textLabel?.text = "+ Add property"
            cell.textLabel?.textColor = .systemBlue
        }
        return cell
    }

    func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        tv.deselectRow(at: ip, animated: true)
        if ip.row < sidecar.user.properties.count {
            editProperty(at: ip.row)
        } else {
            addProperty()
        }
    }

    func tableView(_ tv: UITableView, canEditRowAt ip: IndexPath) -> Bool {
        ip.row < sidecar.user.properties.count
    }

    func tableView(_ tv: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt ip: IndexPath) {
        guard editingStyle == .delete, ip.row < sidecar.user.properties.count else { return }
        sidecar.user.properties.remove(at: ip.row)
        tv.deleteRows(at: [ip], with: .automatic)
    }

    // MARK: - Property editing

    private func addProperty() {
        presentPropertyEditor(existing: nil) { [weak self] new in
            guard let self = self, let new = new else { return }
            self.sidecar.user.properties.append(new)
            self.tableView.reloadData()
        }
    }

    private func editProperty(at index: Int) {
        let current = sidecar.user.properties[index]
        presentPropertyEditor(existing: current) { [weak self] updated in
            guard let self = self, let updated = updated else { return }
            self.sidecar.user.properties[index] = updated
            self.tableView.reloadData()
        }
    }

    private func presentPropertyEditor(existing: UserProperty?, completion: @escaping (UserProperty?) -> Void) {
        let alert = UIAlertController(title: existing == nil ? "Add property" : "Edit property", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "key (e.g. dimensions.length_mm)"; $0.text = existing?.key }
        alert.addTextField { $0.placeholder = "value";                             $0.text = existing?.value }
        alert.addTextField { $0.placeholder = "unit (optional)";                   $0.text = existing?.unit }

        let suggestAction = UIAlertAction(title: "Suggested key…", style: .default) { [weak alert] _ in
            let menu = UIAlertController(title: "Suggested keys", message: nil, preferredStyle: .actionSheet)
            for k in Self.suggestedKeys {
                menu.addAction(.init(title: k, style: .default) { _ in
                    alert?.textFields?[0].text = k
                })
            }
            menu.addAction(.init(title: "Cancel", style: .cancel))
            self.present(menu, animated: true)
        }
        alert.addAction(suggestAction)
        alert.addAction(.init(title: "Cancel", style: .cancel) { _ in completion(nil) })
        alert.addAction(.init(title: existing == nil ? "Add" : "Save", style: .default) { _ in
            let key = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces) ?? ""
            let value = alert.textFields?[1].text ?? ""
            let unit = alert.textFields?[2].text?.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { completion(nil); return }
            completion(UserProperty(key: key, value: value, unit: (unit?.isEmpty ?? true) ? nil : unit))
        })
        present(alert, animated: true)
    }
}
