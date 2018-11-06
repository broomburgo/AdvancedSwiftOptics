import Foundation

enum ActionResult {
    case doThis
    case doThat(value: Int)
    case doThisOtherThing(value: String)
}

extension Int {
    var isPositive: Bool {
        get {
            return self >= 0
        }
        set(shouldBePositive) {
            if isPositive != shouldBePositive {
                self = -self
            }
        }
    }
}

struct Lens<Root, Value> {
    let view: (Root) -> Value
    let update: (Value, Root) -> Root
}

func makeLens<Root, Value>(_ wkp: WritableKeyPath<Root, Value>) -> Lens<Root, Value> {
    return Lens<Root, Value>(
        view: { root in root[keyPath: wkp] },
        update: { newValue, root in
            var m_root = root
            m_root[keyPath: wkp] = newValue
            return m_root
    })
}

extension Lens {
    func modify (_ transformValue: @escaping (Value) -> Value) -> (Root) -> Root {
        return { root in
            self.update(
                transformValue(self.view(root)),
                root)
        }
    }
}

struct LoginPage {
    var username: String
    var password: String
    var isRememberMeActive: Bool
    var isLoginButtonActive: Bool
}

extension LoginPage {
    static func lens<Value>(_ wkp: WritableKeyPath<LoginPage, Value>) -> Lens<LoginPage, Value> {
        return makeLens(wkp)
    }
}

let passwordLens = LoginPage.lens(\.password)

/// trimPassword: (LoginPage) -> LoginPage
let trimPassword = passwordLens.modify {
    $0.trimmingCharacters(in: CharacterSet(charactersIn: " "))
}

func zip<Root, Value1, Value2>(_ lens1: Lens<Root, Value1>, _ lens2: Lens<Root, Value2>) -> Lens<Root, (Value1, Value2)> {
    return Lens<Root, (Value1, Value2)>(
        view: { root in
            (lens1.view(root), lens2.view(root))
    },
        update: { tuple, root in
            lens2.update(tuple.1, lens1.update(tuple.0, root))
    })
}

func zip<Root, Value1, Value2, Value3>(_ lens1: Lens<Root, Value1>, _ lens2: Lens<Root, Value2>, _ lens3: Lens<Root, Value3>) -> Lens<Root, (Value1, Value2, Value3)> {
    return Lens<Root, (Value1, Value2, Value3)>(
        view: { root in
            (lens1.view(root), lens2.view(root), lens3.view(root))
    },
        update: { tuple, root in
            lens3.update(tuple.2, lens2.update(tuple.1, lens1.update(tuple.0, root)))
    })
}

struct UserSession {
    var token: String?
    var currentUsername: String?
    
    static func lens<Value>(_ wkp: WritableKeyPath<UserSession, Value>) -> Lens<UserSession, Value> {
        return makeLens(wkp)
    }
}

struct Application {
    var loginPage: LoginPage
    var userSession: UserSession
    
    static func lens<Value>(_ wkp: WritableKeyPath<Application, Value>) -> Lens<Application, Value> {
        return makeLens(wkp)
    }
}

/// storedUsernameLens: Lens<Application, (String?, String, Bool)>
let storedUsernameLens = zip(
    Application.lens(\.userSession.currentUsername),
    Application.lens(\.loginPage.username),
    Application.lens(\.loginPage.isRememberMeActive)
)

/// restoreUsername: (Application) -> Application
let restoreUsername = storedUsernameLens.modify { current, _, rememberMe in
    guard let current = current, rememberMe else {
        return (nil, "", rememberMe)
    }
    
    return (current, current, rememberMe)
}

extension Dictionary {
    static func lens(at key: Key) -> Lens<Dictionary, Value?> {
        return Lens<Dictionary, Value?>(
            view: { $0[key] },
            update: { value, root in
                var m_root = root
                m_root[key] = value
                return m_root
        })
    }
}

struct Prism<Root, Value> {
    let match: (Root) -> Value?
    let build: (Value) -> Root
}

enum LoginState {
    case idle
    case processing(attempt: Int)
    case failed(error: Error)
    case success(message: String)
}

extension LoginState {
    typealias prism<Value> = Prism<LoginState, Value>
}

extension Prism where Root == LoginState, Value == Int {
    static var processing: LoginState.prism<Int> {
        return .init(
            match: {
                switch $0 {
                case .processing(let attempt):
                    return attempt
                default:
                    return nil
                }
        },
            build: { .processing(attempt: $0) })
    }
}

extension Prism where Root == LoginState, Value == String {
    static var success: LoginState.prism<String> {
        return .init(
            match: {
                switch $0 {
                case .success(let message):
                    return message
                default:
                    return nil
                }
        },
            build: { .success(message: $0) })
    }
}

let currentState = LoginState.idle /// any state
let successPrism = LoginState.prism.success

/// successMessage: String?
let successMessage = successPrism.match(currentState)

extension Prism {
    func tryModify (_ transformValue: @escaping (Value) -> Value) -> (Root) -> Root {
        return { root in
            guard let matched = self.match(root) else {
                return root
            }
            return self.build(transformValue(matched))
        }
    }
}

let processingPrism = LoginState.prism.processing

/// incrementAttemptsIfPossible: (LoginState) -> LoginState
let incrementAttemptsIfPossible = processingPrism.tryModify { $0 + 1 }

enum Event {
    case application(Application)
    case login(Login)
    
    enum Application {
        case didBecomeActive
        case openURL
    }
    
    enum Login {
        case tryLogin(outcome: LoginOutcome)
        case logout(motivation: LogoutMotivation)
        
        enum LoginOutcome {
            case success
            case failure(message: String)
        }
        
        enum LogoutMotivation {
            case manual
            case sessionExpired
        }
    }
}

/// Prism<A, B> + Prism<B, C> = Prism<A, C>

func pipe<A, B, C>(_ prism1: Prism<A, B>, _ prism2: Prism<B, C>) -> Prism<A, C> {
    return Prism<A, C>(
        match: { prism1.match($0).flatMap(prism2.match) },
        build: { prism1.build(prism2.build($0)) })
}

func pipe<A, B, C, D>(_ prism1: Prism<A, B>, _ prism2: Prism<B, C>, _ prism3: Prism<C, D>) -> Prism<A, D> {
    return pipe(
        pipe(
            prism1,
            prism2),
        prism3)
}

extension Event {
    typealias prism<Value> = Prism<Event, Value>
}

extension Prism where Root == Event, Value == Event.Login {
    static var login: Event.prism<Event.Login> {
        return .init(
            match: {
                switch $0 {
                case .login(let value):
                    return value
                default:
                    return nil
                }
        },
            build: { .login($0) })
    }
}

extension Prism where Value == Event.Login {
    var tryLogin: Prism<Root, Event.Login.LoginOutcome> {
        return pipe(self, .tryLogin)
    }
}

extension Event.Login {
    typealias prism<Value> = Prism<Event.Login, Value>
}

extension Prism where Root == Event.Login, Value == Event.Login.LoginOutcome {
    static var tryLogin: Event.Login.prism<Event.Login.LoginOutcome> {
        return .init(
            match: {
                switch $0 {
                case .tryLogin(let outcome):
                    return outcome
                default:
                    return nil
                }
        },
            build: { .tryLogin(outcome: $0) })
    }
}

extension Prism where Value == Event.Login.LoginOutcome {
    var failure: Prism<Root, String> {
        return pipe(self, .failure)
    }
}

extension Event.Login.LoginOutcome {
    typealias prism<Value> = Prism<Event.Login.LoginOutcome, Value>
}

extension Prism where Root == Event.Login.LoginOutcome, Value == String {
    static var failure: Event.Login.LoginOutcome.prism<String> {
        return .init(
            match: {
                switch $0 {
                case .failure(let message):
                    return message
                default:
                    return nil
                }
        },
            build: { .failure(message: $0) })
    }
}

/// failureMessagePrism: Prism<Event, String>
let failureMessagePrism = Event.prism.login.tryLogin.failure

/// uppercasedMessageIfPossible: (Event) -> Event
let uppercasedMessageIfPossible = failureMessagePrism.tryModify { $0.uppercased() }

struct Affine<Root, Value> {
    let preview: (Root) -> Value?
    let tryUpdate: (Value, Root) -> Root?
}

extension Array {
    static func affine(at index: Int) -> Affine<Array, Element> {
        return Affine<Array, Element>(
            preview: { array in
                guard array.indices.contains(index) else { return nil }
                
                return array[index]
        },
            tryUpdate: { element, array in
                guard array.indices.contains(index) else { return nil }
                
                var m_array = array
                m_array.remove(at: index)
                m_array.insert(element, at: index)
                return m_array
        })
    }
    
    static func affineForFirst(where predicate: @escaping (Element) -> Bool) -> Affine<Array, Element> {
        return Affine<Array, Element>(
            preview: { array in
                array.first(where: predicate)
        },
            tryUpdate: { element, array in
                guard let index = array.index(where: predicate) else { return nil }
                
                var m_array = array
                m_array.remove(at: index)
                m_array.insert(element, at: index)
                return m_array
        })
    }
}

extension Lens {
    func toAffine() -> Affine<Root, Value> {
        return Affine<Root, Value>(
            preview: self.view,
            tryUpdate: self.update)
    }
}

extension Prism {
    func toAffine() -> Affine<Root, Value> {
        return Affine<Root, Value>(
            preview: self.match,
            tryUpdate: { value, _ in self.build(value) })
    }
}

func pipe<A, B, C>(_ affine1: Affine<A, B>, _ affine2: Affine<B, C>) -> Affine<A, C> {
    return Affine<A, C>(
        preview: { root in
            affine1.preview(root)
                .flatMap(affine2.preview)
    },
        tryUpdate: { value, root in
            affine1.preview(root)
                .flatMap { affine2.tryUpdate(value, $0) }
                .flatMap { affine1.tryUpdate($0, root) }
    })
}

enum TransactionState {
    case idle
    case failure(String)
    case success([String: TransactionResult])
}

struct TransactionResult {
    var completion: Date
    var outcomes: [TransactionOutcome]
}

struct TransactionOutcome {
    var user: String
    var balance: Double
}

func pipe<A, B, C, D, E, F, G>(_ affine1: Affine<A, B>, _ affine2: Affine<B, C>, _ affine3: Affine<C, D>, _ affine4: Affine<D, E>, _ affine5: Affine<E, F>, _ affine6: Affine<F, G>) -> Affine<A, G> {
    return pipe(pipe(pipe(pipe(pipe(affine1, affine2), affine3), affine4), affine5), affine6)
}

func pipe<A, B, C, D, E, F, G>(_ prism1: Prism<A, B>, _ lens2: Lens<B, C>, _ prism3: Prism<C, D>, _ lens4: Lens<D, E>, _ affine5: Affine<E, F>, _ lens6: Lens<F, G>) -> Affine<A, G> {
    return pipe(prism1.toAffine(), lens2.toAffine(), prism3.toAffine(), lens4.toAffine(), affine5, lens6.toAffine())
}

extension Optional {
    static var prism: Prism<Optional, Wrapped> {
        return Prism<Optional, Wrapped>(
            match: { $0 },
            build: { .some($0) })
    }
}

extension TransactionState {
    typealias prism<Value> = Prism<TransactionState, Value>
}

extension Prism where Root == TransactionState, Value == [String: TransactionResult] {
    static var success: TransactionState.prism<[String: TransactionResult]> {
        return .init(
            match: {
                switch $0 {
                case .success(let value):
                    return value
                default:
                    return nil
                }
        },
            build: { .success($0) })
    }
}

extension TransactionResult {
    static func lens<Value>(_ wkp: WritableKeyPath<TransactionResult, Value>) -> Lens<TransactionResult, Value> {
        return makeLens(wkp)
    }
}

extension TransactionOutcome {
    static func lens<Value>(_ wkp: WritableKeyPath<TransactionOutcome, Value>) -> Lens<TransactionOutcome, Value> {
        return makeLens(wkp)
    }
}

let ultimateAffine = pipe(
    
    TransactionState.prism.success,
    
    Dictionary.lens(at: "IllRememberThis"),
    
    Optional.prism,
    
    TransactionResult.lens(\.outcomes),
    
    Array.affineForFirst { $0.user == "Siri McSirison" },
    
    TransactionOutcome.lens(\.balance)
)

