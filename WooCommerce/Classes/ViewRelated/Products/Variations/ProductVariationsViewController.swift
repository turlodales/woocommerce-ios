import UIKit
import WordPressUI
import Yosemite

import class AutomatticTracks.CrashLogging

/// Displays a paginated list of Product Variations with its price or visibility.
///
final class ProductVariationsViewController: UIViewController {

    /// Empty state screen
    ///
    private lazy var emptyStateViewController = EmptyStateViewController(style: .list)

    /// Empty state screen configuration
    ///
    private lazy var emptyStateConfig: EmptyStateViewController.Config = {
        let message = NSAttributedString(string: "Add your first variation", attributes: [.font: EmptyStateViewController.Config.messageFont])
        return .withButton(message: message,
                           image: .emptyBoxImage,
                           details: "",
                           buttonTitle: "Add Variations") { [weak self] in
                            self?.navigateToAddAttributeViewController()
                           }
    }()

    @IBOutlet private weak var tableView: UITableView!

    /// Pull To Refresh Support.
    ///
    private lazy var refreshControl: UIRefreshControl = {
        let refreshControl = UIRefreshControl()
        refreshControl.addTarget(self, action: #selector(pullToRefresh(sender:)), for: .valueChanged)
        return refreshControl
    }()

    /// Stack view that contains the top warning banner and is contained in the table view header.
    ///
    private lazy var topStackView: UIStackView = {
        let stackView = UIStackView(arrangedSubviews: [])
        stackView.axis = .vertical
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }()

    /// Top banner that shows a warning in case some variations are missing a price.
    ///
    private lazy var topBannerView: TopBannerView = {
        let topBanner = ProductVariationsTopBannerFactory.missingPricesTopBannerView()
        topBanner.translatesAutoresizingMaskIntoConstraints = false
        return topBanner
    }()

    /// Footer "Loading More" Spinner.
    ///
    private lazy var footerSpinnerView = FooterSpinnerView()

    /// Empty Footer Placeholder. Replaces spinner view and allows footer to collapse and be completely hidden.
    ///
    private lazy var footerEmptyView = UIView(frame: .zero)

    /// ResultsController: Surrounds us. Binds the galaxy together. And also, keeps the UITableView <> (Stored) Product Variations in sync.
    ///
    private lazy var resultsController: ResultsController<StorageProductVariation> = {
        let resultsController = createResultsController()
        configureResultsController(resultsController)
        return resultsController
    }()

    /// Keep track of the (Autosizing Cell's) Height. This helps us prevent UI flickers, due to sizing recalculations.
    ///
    private var estimatedRowHeights = [IndexPath: CGFloat]()

    /// Indicates if there are no results onscreen.
    ///
    private var isEmpty: Bool {
        return resultsController.isEmpty
    }

    /// SyncCoordinator: Keeps tracks of which pages have been refreshed, and encapsulates the "What should we sync now" logic.
    ///
    private let syncingCoordinator = SyncingCoordinator()

    private lazy var stateCoordinator: PaginatedListViewControllerStateCoordinator = {
        let stateCoordinator = PaginatedListViewControllerStateCoordinator(onLeavingState: { [weak self] state in
            self?.didLeave(state: state)
            }, onEnteringState: { [weak self] state in
                self?.didEnter(state: state)
        })
        return stateCoordinator
    }()

    private let product: Product
    private let siteID: Int64
    private let productID: Int64
    private let allAttributes: [ProductAttribute]
    private let parentProductSKU: String?
    private let formType: ProductFormType

    private let imageService: ImageService = ServiceLocator.imageService
    private let isAddProductVariationsEnabled: Bool

    init(product: Product, formType: ProductFormType, isAddProductVariationsEnabled: Bool) {
        self.product = product
        self.siteID = product.siteID
        self.productID = product.productID
        self.allAttributes = product.attributes
        self.parentProductSKU = product.sku
        self.formType = formType
        self.isAddProductVariationsEnabled = isAddProductVariationsEnabled
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        configureNavigationBar()
        configureMainView()
        configureTableView()
        configureSyncingCoordinator()
        registerTableViewCells()
        configureTopBannerContainerView()
        updateTopBannerView()

        syncingCoordinator.synchronizeFirstPage()

        if product.variations.isEmpty {
            displayEmptyViewController()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        tableView.updateHeaderHeight()
    }
}


// MARK: - View Configuration
//
private extension ProductVariationsViewController {

    /// Set the title.
    ///
    func configureNavigationBar() {
        title = NSLocalizedString(
            "Variations",
            comment: "Title that appears on top of the Product Variation List screen."
        )
    }

    /// Apply Woo styles.
    ///
    func configureMainView() {
        view.backgroundColor = .listBackground
    }

    /// Configure common table properties.
    ///
    func configureTableView() {
        tableView.dataSource = self
        tableView.delegate = self

        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.estimatedRowHeight = Settings.estimatedRowHeight
        tableView.rowHeight = UITableView.automaticDimension

        // Removes extra header spacing in ghost content view.
        tableView.estimatedSectionHeaderHeight = 0
        tableView.sectionHeaderHeight = 0

        tableView.backgroundColor = .listBackground
        tableView.refreshControl = refreshControl
        tableView.tableFooterView = footerSpinnerView
    }

    /// Setup: Sync'ing Coordinator
    ///
    func configureSyncingCoordinator() {
        syncingCoordinator.delegate = self
    }

    /// Register table cells.
    ///
    func registerTableViewCells() {
        tableView.register(ProductsTabProductTableViewCell.self)
    }

    /// Shows the EmptyStateViewController
    ///
    private func displayEmptyViewController() {
        addChild(emptyStateViewController)

        emptyStateViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyStateViewController.view)

        emptyStateViewController.view.pinSubviewToAllEdges(view)
        emptyStateViewController.didMove(toParent: self)
        emptyStateViewController.configure(emptyStateConfig)
    }

    func removeEmptyViewController() {
        guard emptyStateViewController.parent == self else {
            return
        }

        emptyStateViewController.willMove(toParent: nil)
        emptyStateViewController.view.removeFromSuperview()
        emptyStateViewController.removeFromParent()
    }
}

private extension ProductVariationsViewController {
    func configureTopBannerContainerView() {
        let headerContainer = UIView(frame: CGRect(x: 0, y: 0, width: Int(tableView.frame.width), height: 0))
        headerContainer.addSubview(topStackView)
        headerContainer.pinSubviewToSafeArea(topStackView)
        topStackView.addArrangedSubview(topBannerView)

        tableView.tableHeaderView = headerContainer
    }

    func updateTopBannerView() {
        let hasVariationsMissingPrice = resultsController.fetchedObjects.contains {
            EditableProductVariationModel(productVariation: $0,
                                          allAttributes: allAttributes,
                                          parentProductSKU: parentProductSKU)
                .isEnabledAndMissingPrice
        }
        topBannerView.isHidden = hasVariationsMissingPrice == false
        tableView.updateHeaderHeight()
    }
}

// MARK: - ResultsController
//
private extension ProductVariationsViewController {
    func createResultsController() -> ResultsController<StorageProductVariation> {
        let storageManager = ServiceLocator.storageManager
        let predicate = NSPredicate(format: "product.siteID == %lld AND product.productID == %lld", siteID, productID)
        let descriptor = NSSortDescriptor(keyPath: \StorageProductVariation.menuOrder, ascending: true)

        return ResultsController<StorageProductVariation>(storageManager: storageManager,
                                                          matching: predicate,
                                                          sortedBy: [descriptor])
    }

    func configureResultsController(_ resultsController: ResultsController<StorageProductVariation>) {
        configureResultsControllerEventHandling(resultsController)

        do {
            try resultsController.performFetch()
        } catch {
            CrashLogging.logError(error)
        }

        tableView.reloadData()
    }

    func configureResultsControllerEventHandling(_ resultsController: ResultsController<StorageProductVariation>) {
        let onReload = { [weak self] in
            self?.tableView.reloadData()
            self?.updateTopBannerView()
        }

        resultsController.onDidChangeContent = { [weak tableView] in
            tableView?.endUpdates()
            onReload()
        }

        resultsController.onDidResetContent = {
            onReload()
        }
    }
}

// MARK: - UITableViewDataSource Conformance
//
extension ProductVariationsViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        return resultsController.sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return resultsController.sections[section].numberOfObjects
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(ProductsTabProductTableViewCell.self, for: indexPath)

        let productVariation = resultsController.object(at: indexPath)
        let model = EditableProductVariationModel(productVariation: productVariation,
                                                  allAttributes: allAttributes,
                                                  parentProductSKU: parentProductSKU)

        let viewModel = ProductsTabProductViewModel(productVariationModel: model)
        cell.update(viewModel: viewModel, imageService: imageService)
        cell.selectionStyle = .none
        cell.accessoryType = .disclosureIndicator

        return cell
    }
}


// MARK: - UITableViewDelegate Conformance
//
extension ProductVariationsViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return estimatedRowHeights[indexPath] ?? Settings.estimatedRowHeight
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        ServiceLocator.analytics.track(.productVariationListVariationTapped)

        let productVariation = resultsController.object(at: indexPath)
        let model = EditableProductVariationModel(productVariation: productVariation,
                                                  allAttributes: allAttributes,
                                                  parentProductSKU: parentProductSKU)

        let currencyCode = ServiceLocator.currencySettings.currencyCode
        let currency = ServiceLocator.currencySettings.symbol(from: currencyCode)
        let productImageActionHandler = ProductImageActionHandler(siteID: productVariation.siteID,
                                                                  product: model)
        let viewModel = ProductVariationFormViewModel(productVariation: model,
                                                      allAttributes: allAttributes,
                                                      parentProductSKU: parentProductSKU,
                                                      formType: formType,
                                                      productImageActionHandler: productImageActionHandler)
        let viewController = ProductFormViewController(viewModel: viewModel,
                                                       eventLogger: ProductVariationFormEventLogger(),
                                                       productImageActionHandler: productImageActionHandler,
                                                       currency: currency,
                                                       presentationStyle: .navigationStack,
                                                       isAddProductVariationsEnabled: isAddProductVariationsEnabled)
        navigationController?.pushViewController(viewController, animated: true)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let productIndex = resultsController.objectIndex(from: indexPath)
        syncingCoordinator.ensureNextPageIsSynchronized(lastVisibleIndex: productIndex)

        // Preserve the Cell Height
        // Why: Because Autosizing Cells, upon reload, will need to be laid yout yet again. This might cause
        // UI glitches / unwanted animations. By preserving it, *then* the estimated will be extremely close to
        // the actual value. AKA no flicker!
        //
        estimatedRowHeights[indexPath] = cell.frame.height
    }
}

// MARK: Navigation
private extension ProductVariationsViewController {
    func navigateToAddAttributeViewController() {
        let viewModel = AddAttributeViewModel(product: product)
        let addAttributeViewController = AddAttributeViewController(viewModel: viewModel)
        show(addAttributeViewController, sender: self)
    }
}

private extension ProductVariationsViewController {
    @objc private func pullToRefresh(sender: UIRefreshControl) {
        ServiceLocator.analytics.track(.productVariationListPulledToRefresh)

        syncingCoordinator.synchronizeFirstPage {
            sender.endRefreshing()
        }
    }
}

// MARK: - Placeholders
//
private extension ProductVariationsViewController {

    /// Renders the Placeholder Orders: For safety reasons, we'll also halt ResultsController <> UITableView glue.
    ///
    func displayPlaceholderProducts() {
        let options = GhostOptions(reuseIdentifier: ProductsTabProductTableViewCell.reuseIdentifier, rowsPerSection: Settings.placeholderRowsPerSection)
        tableView.displayGhostContent(options: options, style: .wooDefaultGhostStyle)

        resultsController.stopForwardingEvents()
    }

    /// Removes the Placeholder Products (and restores the ResultsController <> UITableView link).
    ///
    func removePlaceholderProducts() {
        tableView.removeGhostContent()
        resultsController.startForwardingEvents(to: tableView)
        configureResultsControllerEventHandling(resultsController)
        tableView.reloadData()
    }

    /// Displays the Error Notice.
    ///
    func displaySyncingErrorNotice(pageNumber: Int, pageSize: Int) {
        let message = NSLocalizedString("Unable to refresh list", comment: "Refresh Action Failed")
        let actionTitle = NSLocalizedString("Retry", comment: "Retry Action")
        let notice = Notice(title: message, feedbackType: .error, actionTitle: actionTitle) { [weak self] in
            self?.sync(pageNumber: pageNumber, pageSize: pageSize)
        }

        ServiceLocator.noticePresenter.enqueue(notice: notice)
    }
}

// MARK: - Sync'ing Helpers
//
extension ProductVariationsViewController: SyncingCoordinatorDelegate {

    /// Synchronizes the Product Variations for the Default Store (if any).
    ///
    func sync(pageNumber: Int, pageSize: Int, reason: String? = nil, onCompletion: ((Bool) -> Void)? = nil) {
        transitionToSyncingState(pageNumber: pageNumber)

        let action = ProductVariationAction
            .synchronizeProductVariations(siteID: siteID, productID: productID, pageNumber: pageNumber, pageSize: pageSize) { [weak self] error in
                guard let self = self else {
                    return
                }

                if let error = error {
                    ServiceLocator.analytics.track(.productVariationListLoadError, withError: error)

                    DDLogError("⛔️ Error synchronizing product variations: \(error)")
                    self.displaySyncingErrorNotice(pageNumber: pageNumber, pageSize: pageSize)
                } else {
                    ServiceLocator.analytics.track(.productVariationListLoaded)
                }

                self.transitionToResultsUpdatedState()
                onCompletion?(error == nil)
        }

        ServiceLocator.stores.dispatch(action)
    }
}

// MARK: - Finite State Machine Management
//
private extension ProductVariationsViewController {

    func didEnter(state: PaginatedListViewControllerState) {
        switch state {
        case .noResultsPlaceholder:
            break
        case .syncing(let pageNumber):
            if pageNumber == SyncingCoordinator.Defaults.pageFirstIndex {
                displayPlaceholderProducts()
            } else {
                ensureFooterSpinnerIsStarted()
            }
        case .results:
            break
        }
    }

    func didLeave(state: PaginatedListViewControllerState) {
        switch state {
        case .noResultsPlaceholder:
            removeEmptyViewController()
        case .syncing:
            ensureFooterSpinnerIsStopped()
            removePlaceholderProducts()
        case .results:
            break
        }
    }

    func transitionToSyncingState(pageNumber: Int) {
        stateCoordinator.transitionToSyncingState(pageNumber: pageNumber)
    }

    func transitionToResultsUpdatedState() {
        stateCoordinator.transitionToResultsUpdatedState(hasData: !isEmpty)
        updateTopBannerView()
    }
}

// MARK: - Spinner Helpers
//
extension ProductVariationsViewController {

    /// Starts the Footer Spinner animation, whenever `mustStartFooterSpinner` returns *true*.
    ///
    private func ensureFooterSpinnerIsStarted() {
        guard mustStartFooterSpinner() else {
            return
        }

        tableView.tableFooterView = footerSpinnerView
        footerSpinnerView.startAnimating()
    }

    /// Whenever we're sync'ing an Products Page that's beyond what we're currently displaying, this method will return *true*.
    ///
    private func mustStartFooterSpinner() -> Bool {
        guard let highestPageBeingSynced = syncingCoordinator.highestPageBeingSynced else {
            return false
        }

        return highestPageBeingSynced * SyncingCoordinator.Defaults.pageSize > resultsController.numberOfObjects
    }

    /// Stops animating the Footer Spinner.
    ///
    private func ensureFooterSpinnerIsStopped() {
        footerSpinnerView.stopAnimating()
        tableView.tableFooterView = footerEmptyView
    }
}

// MARK: - Nested Types
//
private extension ProductVariationsViewController {

    enum Settings {
        static let estimatedRowHeight = CGFloat(86)
        static let placeholderRowsPerSection = [3]
    }
}
