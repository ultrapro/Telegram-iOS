import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
    import MtProtoKitMac
#else
    import Postbox
    import SwiftSignalKit
    import MtProtoKitDynamic
#endif

private enum AccountKind {
    case authorized
    case unauthorized
}

public func currentAccount(apiId: Int32, manager: AccountManager, appGroupPath: String, testingEnvironment: Bool) -> Signal<Either<UnauthorizedAccount, Account>?, NoError> {
    return manager.allocatedCurrentAccountId()
        |> distinctUntilChanged(isEqual: { lhs, rhs in
            return lhs == rhs
        })
        |> mapToSignal { id -> Signal<Either<UnauthorizedAccount, Account>?, NoError> in
            if let id = id {
                let reload = ValuePromise<Bool>(true, ignoreRepeated: false)
                return reload.get() |> mapToSignal { _ -> Signal<Either<UnauthorizedAccount, Account>?, NoError> in
                    return accountWithId(apiId: apiId, id: id, appGroupPath: appGroupPath, testingEnvironment: testingEnvironment)
                        |> mapToSignal { account -> Signal<Either<UnauthorizedAccount, Account>?, NoError> in
                            let postbox: Postbox
                            let initialKind: AccountKind
                            switch account {
                                case let .left(value: account):
                                    postbox = account.postbox
                                    initialKind = .unauthorized
                                case let.right(value: account):
                                    postbox = account.postbox
                                    initialKind = .authorized
                            }
                            let updatedKind = postbox.stateView()
                                |> map { view -> Bool in
                                    let kind: AccountKind
                                    if view.state is AuthorizedAccountState {
                                        kind = .authorized
                                    } else {
                                        kind = .unauthorized
                                    }
                                    if kind != initialKind {
                                        return true
                                    } else {
                                        return false
                                    }
                                }
                                |> distinctUntilChanged
                            
                            return Signal { subscriber in
                                subscriber.putNext(account)
                                
                                return updatedKind.start(next: { value in
                                    if value {
                                        reload.set(true)
                                    }
                                })
                            }
                        }
                }
            } else {
                return .single(nil)
            }
        }
}

public func logoutFromAccount(id: AccountRecordId, accountManager: AccountManager) -> Signal<Void, NoError> {
    return accountManager.modify { modifier -> Void in
        let currentId = modifier.getCurrentId()
        if let currentId = currentId {
            modifier.updateRecord(currentId, { current in
                if let current = current {
                    var found = false
                    for attribute in current.attributes {
                        if attribute is LoggedOutAccountAttribute {
                            found = true
                            break
                        }
                    }
                    if found {
                        return current
                    } else {
                        return AccountRecord(id: current.id, attributes: current.attributes + [LoggedOutAccountAttribute()])
                    }
                } else {
                    return nil
                }
            })
            let id = modifier.createRecord([])
            modifier.setCurrentId(id)
        }
    }
}

public func managedCleanupAccounts(apiId: Int32, accountManager: AccountManager, appGroupPath: String) -> Signal<Void, NoError> {
    return Signal { subscriber in
        let loggedOutAccounts = Atomic<[AccountRecordId: MetaDisposable]>(value: [:])
        let disposable = accountManager.accountRecords().start(next: { view in
            var disposeList: [(AccountRecordId, MetaDisposable)] = []
            var beginList: [(AccountRecordId, MetaDisposable)] = []
            let _ = loggedOutAccounts.modify { disposables in
                let validIds = Set(view.records.filter {
                    for attribute in $0.attributes {
                        if attribute is LoggedOutAccountAttribute {
                            return true
                        }
                    }
                    return false
                }.map { $0.id })
                
                
                var disposables = disposables
                
                for id in disposables.keys {
                    if !validIds.contains(id) {
                        disposeList.append((id, disposables[id]!))
                    }
                }
                
                for (id, _) in disposeList {
                    disposables.removeValue(forKey: id)
                }
                
                for id in validIds {
                    if disposables[id] == nil {
                        let disposable = MetaDisposable()
                        beginList.append((id, disposable))
                        disposables[id] = disposable
                    }
                }
                
                return disposables
            }
            for (_, disposable) in disposeList {
                disposable.dispose()
            }
            for (id, disposable) in beginList {
                disposable.set(cleanupAccount(apiId: apiId, accountManager: accountManager, id: id, appGroupPath: appGroupPath).start())
            }
        })
        
        return ActionDisposable {
            disposable.dispose()
        }
    }
}


private func cleanupAccount(apiId: Int32, accountManager: AccountManager, id: AccountRecordId, appGroupPath: String) -> Signal<Void, NoError> {
    return accountWithId(apiId: apiId, id: id, appGroupPath: appGroupPath, testingEnvironment: false)
        |> mapToSignal { account -> Signal<Void, NoError> in
            switch account {
                case .left:
                    return .complete()
                case let .right(account):
                    account.shouldBeServiceTaskMaster.set(.single(.always))
                    return account.network.request(Api.functions.auth.logOut())
                        |> map { Optional($0) }
                        |> `catch` { _ -> Signal<Api.Bool?, NoError> in
                            return .single(.boolFalse)
                        }
                        |> mapToSignal { _ -> Signal<Void, NoError> in
                            account.shouldBeServiceTaskMaster.set(.single(.never))
                            return accountManager.modify { modifier -> Void in
                                modifier.updateRecord(id, { _ in
                                    return nil
                                })
                            }
                        }
            }
        }
}
