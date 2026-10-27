//
//  ManualPhotoGalleryViewController.swift
//  RTABMapApp
//
//  Grid of photos in the current ManualPhotoStore session.
//

import UIKit

final class ManualPhotoGalleryViewController: UICollectionViewController, PhotoMetadataEditorDelegate {

    private var entries: [ManualPhotoStore.PhotoEntry] = []
    private let thumbCache = NSCache<NSURL, UIImage>()

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 100, height: 100)
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        super.init(collectionViewLayout: layout)
        title = "Manual Photos"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .systemBackground
        collectionView.register(ThumbCell.self, forCellWithReuseIdentifier: "thumb")
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        entries = ManualPhotoStore.shared.currentPhotos()
        title = "Manual Photos (\(entries.count))"
        collectionView.reloadData()
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    // MARK: - CollectionView

    override func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int {
        entries.count
    }

    override func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "thumb", for: ip) as! ThumbCell
        let entry = entries[ip.item]
        let key = entry.jpegURL as NSURL
        if let cached = thumbCache.object(forKey: key) {
            cell.imageView.image = cached
        } else {
            cell.imageView.image = nil
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                if let full = UIImage(contentsOfFile: entry.jpegURL.path) {
                    let thumb = Self.downsample(full, to: CGSize(width: 200, height: 200))
                    self.thumbCache.setObject(thumb, forKey: key)
                    DispatchQueue.main.async {
                        if cv.indexPath(for: cell) == ip { cell.imageView.image = thumb }
                    }
                }
            }
        }
        return cell
    }

    override func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        let entry = entries[ip.item]
        let editor = PhotoMetadataEditor(jpegURL: entry.jpegURL, sidecar: entry.sidecar)
        editor.delegate = self
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    // MARK: - Editor delegate

    func editor(_ editor: PhotoMetadataEditor, didSave sidecar: PhotoSidecar, at jpegURL: URL) { reload() }
    func editor(_ editor: PhotoMetadataEditor, didDelete jpegURL: URL) {
        thumbCache.removeObject(forKey: jpegURL as NSURL)
        reload()
    }

    // MARK: - Helpers

    private static func downsample(_ image: UIImage, to target: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private final class ThumbCell: UICollectionViewCell {
        let imageView = UIImageView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.backgroundColor = .secondarySystemBackground
            imageView.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
                imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }
        required init?(coder: NSCoder) { fatalError() }
    }
}
