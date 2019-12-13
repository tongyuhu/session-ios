//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc
public protocol ConversationSearchControllerDelegate: UISearchControllerDelegate {

    @objc
    func conversationSearchController(_ conversationSearchController: ConversationSearchController,
                                      didUpdateSearchResults resultSet: ConversationScreenSearchResultSet?)

    @objc
    func conversationSearchController(_ conversationSearchController: ConversationSearchController,
                                      didSelectMessageId: String)
}

@objc
public class ConversationSearchController: NSObject {

    @objc
    public static let kMinimumSearchTextLength: UInt = 2

    @objc
    public let uiSearchController =  UISearchController(searchResultsController: nil)

    @objc
    public weak var delegate: ConversationSearchControllerDelegate?

    let thread: TSThread

    @objc
    public let resultsBar: SearchResultsBar = SearchResultsBar(frame: .zero)

    // MARK: Initializer

    @objc
    required public init(thread: TSThread) {
        self.thread = thread
        super.init()

        resultsBar.resultsBarDelegate = self
        uiSearchController.delegate = self
        uiSearchController.searchResultsUpdater = self

        uiSearchController.hidesNavigationBarDuringPresentation = false
        uiSearchController.dimsBackgroundDuringPresentation = false
        uiSearchController.searchBar.inputAccessoryView = resultsBar

        applyTheme()
    }

    func applyTheme() {
        OWSSearchBar.applyTheme(to: uiSearchController.searchBar)
    }

    // MARK: Dependencies

    var dbReadConnection: YapDatabaseConnection {
        return OWSPrimaryStorage.shared().dbReadConnection
    }
}

extension ConversationSearchController: UISearchControllerDelegate {
    public func didPresentSearchController(_ searchController: UISearchController) {
        Logger.verbose("")
        delegate?.didPresentSearchController?(searchController)
    }

    public func didDismissSearchController(_ searchController: UISearchController) {
        Logger.verbose("")
        delegate?.didDismissSearchController?(searchController)
    }
}

extension ConversationSearchController: UISearchResultsUpdating {
    var dbSearcher: FullTextSearcher {
        return FullTextSearcher.shared
    }

    public func updateSearchResults(for searchController: UISearchController) {
        Logger.verbose("searchBar.text: \( searchController.searchBar.text ?? "<blank>")")

        guard let rawSearchText = searchController.searchBar.text?.stripped else {
            self.resultsBar.updateResults(resultSet: nil)
            self.delegate?.conversationSearchController(self, didUpdateSearchResults: nil)
            return
        }
        let searchText = FullTextSearchFinder.normalize(text: rawSearchText)
        BenchManager.startEvent(title: "Conversation Search", eventId: searchText)

        guard searchText.count >= ConversationSearchController.kMinimumSearchTextLength else {
            self.resultsBar.updateResults(resultSet: nil)
            self.delegate?.conversationSearchController(self, didUpdateSearchResults: nil)
            return
        }

        var resultSet: ConversationScreenSearchResultSet?
        self.dbReadConnection.asyncRead({ [weak self] transaction in
            guard let self = self else {
                return
            }
            resultSet = self.dbSearcher.searchWithinConversation(thread: self.thread, searchText: searchText, transaction: transaction)
        }, completionBlock: { [weak self] in
            guard let self = self else {
                return
            }
            self.resultsBar.updateResults(resultSet: resultSet)
            self.delegate?.conversationSearchController(self, didUpdateSearchResults: resultSet)
        })
    }
}

extension ConversationSearchController: SearchResultsBarDelegate {
    func searchResultsBar(_ searchResultsBar: SearchResultsBar,
                          setCurrentIndex currentIndex: Int,
                          resultSet: ConversationScreenSearchResultSet) {
        guard let searchResult = resultSet.messages[safe: currentIndex] else {
            owsFailDebug("messageId was unexpectedly nil")
            return
        }

        BenchEventStart(title: "Conversation Search Nav", eventId: "Conversation Search Nav: \(searchResult.messageId)")
        self.delegate?.conversationSearchController(self, didSelectMessageId: searchResult.messageId)
    }
}

protocol SearchResultsBarDelegate: AnyObject {
    func searchResultsBar(_ searchResultsBar: SearchResultsBar,
                          setCurrentIndex currentIndex: Int,
                          resultSet: ConversationScreenSearchResultSet)
}

public class SearchResultsBar: UIToolbar {

    weak var resultsBarDelegate: SearchResultsBarDelegate?

    var showLessRecentButton: UIBarButtonItem!
    var showMoreRecentButton: UIBarButtonItem!
    let labelItem: UIBarButtonItem

    var resultSet: ConversationScreenSearchResultSet?

    override init(frame: CGRect) {

        labelItem = UIBarButtonItem(title: nil, style: .plain, target: nil, action: nil)
        labelItem.setTitleTextAttributes([ .font : UIFont.systemFont(ofSize: Values.mediumFontSize) ], for: UIControl.State.normal)

        super.init(frame: frame)

        let leftExteriorChevronMargin: CGFloat
        let leftInteriorChevronMargin: CGFloat
        if CurrentAppContext().isRTL {
            leftExteriorChevronMargin = 8
            leftInteriorChevronMargin = 0
        } else {
            leftExteriorChevronMargin = 0
            leftInteriorChevronMargin = 8
        }

        let upChevron = #imageLiteral(resourceName: "ic_chevron_up").withRenderingMode(.alwaysTemplate)
        showLessRecentButton = UIBarButtonItem(image: upChevron, style: .plain, target: self, action: #selector(didTapShowLessRecent))
        showLessRecentButton.imageInsets = UIEdgeInsets(top: 2, left: leftExteriorChevronMargin, bottom: 2, right: leftInteriorChevronMargin)
        showLessRecentButton.tintColor = Colors.accent

        let downChevron = #imageLiteral(resourceName: "ic_chevron_down").withRenderingMode(.alwaysTemplate)
        showMoreRecentButton = UIBarButtonItem(image: downChevron, style: .plain, target: self, action: #selector(didTapShowMoreRecent))
        showMoreRecentButton.imageInsets = UIEdgeInsets(top: 2, left: leftInteriorChevronMargin, bottom: 2, right: leftExteriorChevronMargin)
        showMoreRecentButton.tintColor = Colors.accent

        let spacer1 = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let spacer2 = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)

        self.items = [showLessRecentButton, showMoreRecentButton, spacer1, labelItem, spacer2]

        self.isTranslucent = false
        self.isOpaque = true
        self.barTintColor = Colors.navigationBarBackground

        self.autoresizingMask = .flexibleHeight
        self.translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder aDecoder: NSCoder) {
        notImplemented()
    }

    @objc
    public func didTapShowLessRecent() {
        Logger.debug("")
        guard let resultSet = resultSet else {
            owsFailDebug("resultSet was unexpectedly nil")
            return
        }

        guard let currentIndex = currentIndex else {
            owsFailDebug("currentIndex was unexpectedly nil")
            return
        }

        guard currentIndex + 1 < resultSet.messages.count else {
            owsFailDebug("showLessRecent button should be disabled")
            return
        }

        let newIndex = currentIndex + 1
        self.currentIndex = newIndex
        updateBarItems()
        resultsBarDelegate?.searchResultsBar(self, setCurrentIndex: newIndex, resultSet: resultSet)
    }

    @objc
    public func didTapShowMoreRecent() {
        Logger.debug("")
        guard let resultSet = resultSet else {
            owsFailDebug("resultSet was unexpectedly nil")
            return
        }

        guard let currentIndex = currentIndex else {
            owsFailDebug("currentIndex was unexpectedly nil")
            return
        }

        guard currentIndex > 0 else {
            owsFailDebug("showMoreRecent button should be disabled")
            return
        }

        let newIndex = currentIndex - 1
        self.currentIndex = newIndex
        updateBarItems()
        resultsBarDelegate?.searchResultsBar(self, setCurrentIndex: newIndex, resultSet: resultSet)
    }

    var currentIndex: Int?

    // MARK: 

    func updateResults(resultSet: ConversationScreenSearchResultSet?) {
        if let resultSet = resultSet {
            if resultSet.messages.count > 0 {
                currentIndex = min(currentIndex ?? 0, resultSet.messages.count - 1)
            } else {
                currentIndex = nil
            }
        } else {
            currentIndex = nil
        }

        self.resultSet = resultSet

        updateBarItems()
        if let currentIndex = currentIndex, let resultSet = resultSet {
            resultsBarDelegate?.searchResultsBar(self, setCurrentIndex: currentIndex, resultSet: resultSet)
        }
    }

    func updateBarItems() {
        guard let resultSet = resultSet else {
            labelItem.title = nil
            showMoreRecentButton.isEnabled = false
            showLessRecentButton.isEnabled = false
            return
        }

        switch resultSet.messages.count {
        case 0:
            labelItem.title = NSLocalizedString("CONVERSATION_SEARCH_NO_RESULTS", comment: "keyboard toolbar label when no messages match the search string")
        case 1:
            labelItem.title = NSLocalizedString("CONVERSATION_SEARCH_ONE_RESULT", comment: "keyboard toolbar label when exactly 1 message matches the search string")
        default:
            let format = NSLocalizedString("CONVERSATION_SEARCH_RESULTS_FORMAT",
                                           comment: "keyboard toolbar label when more than 1 message matches the search string. Embeds {{number/position of the 'currently viewed' result}} and the {{total number of results}}")

            guard let currentIndex = currentIndex else {
                owsFailDebug("currentIndex was unexpectedly nil")
                return
            }
            labelItem.title = String(format: format, currentIndex + 1, resultSet.messages.count)
        }

        if let currentIndex = currentIndex {
            showMoreRecentButton.isEnabled = currentIndex > 0
            showLessRecentButton.isEnabled = currentIndex + 1 < resultSet.messages.count
        } else {
            showMoreRecentButton.isEnabled = false
            showLessRecentButton.isEnabled = false
        }
    }
}
