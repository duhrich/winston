//
//  CommentData.swift
//  winston
//
//  Created by Igor Marcossi on 28/06/23.
//

import Foundation
import Defaults
import SwiftUI
import CoreData

typealias Comment = GenericRedditEntity<CommentData>

enum RandomErr: Error {
  case oops
}

enum CommentParentElement {
  case post(ObservableArray<Comment>)
  case comment(Comment)
  
  var isPost: Bool {
    switch self {
    case .comment(_):
      return false
    case .post(_):
      return true
    }
  }
}

extension Comment {
  static var prefix = "t1"
  convenience init(data: T, api: RedditAPI, kind: String? = nil, parent: ObservableArray<GenericRedditEntity<T>>? = nil) {
    self.init(data: data, api: api, typePrefix: "\(Comment.prefix)_")
    if let parent = parent {
      self.parentWinston = parent
    }
    self.kind = kind
    if let body = self.data?.body {
      let newWinstonBodyAttr = stringToAttr(body, fontSize: Defaults[.commentLinkBodySize])
      let encoder = JSONEncoder()
      if let jsonData = try? encoder.encode(newWinstonBodyAttr) {
        let json = String(decoding: jsonData, as: UTF8.self)
        self.data?.winstonBodyAttrEncoded = json
      }
    }
    if let replies = self.data?.replies {
      switch replies {
      case .first(_):
        break
      case.second(let listing):
        self.childrenWinston.data = listing.data?.children?.compactMap { x in
          if let innerData = x.data {
            let newComment = Comment(data: innerData, api: redditAPI, kind: x.kind, parent: self.childrenWinston)
            return newComment
          }
          return nil
        } ?? []
      }
    }
  }
  
  convenience init(message: Message) throws {
    let rawMessage = message
    if let message = message.data {
      var commentData = CommentData(id: message.id)
      commentData.subreddit_id = nil
      commentData.subreddit = message.subreddit
      commentData.likes = nil
      commentData.replies = .first("")
      commentData.saved = false
      commentData.archived = false
      commentData.count = nil
      commentData.author = message.author
      commentData.created_utc = message.created_utc
      commentData.send_replies = false
      commentData.parent_id = message.parent_id
      commentData.score = nil
      commentData.author_fullname = message.author_fullname
      commentData.approved_by = nil
      commentData.mod_note = nil
      commentData.collapsed = false
      commentData.body = message.body
      commentData.top_awarded_type = nil
      commentData.name = message.name
      commentData.is_submitter = nil
      commentData.downs = nil
      commentData.children = nil
      commentData.body_html = message.body_html
      commentData.permalink = nil
      commentData.created = message.created
      commentData.link_id = nil
      commentData.link_title = message.link_title
      commentData.subreddit_name_prefixed = message.subreddit_name_prefixed
      commentData.depth = nil
      commentData.author_flair_background_color = nil
      commentData.collapsed_because_crowd_control = nil
      commentData.mod_reports = nil
      commentData.num_reports = nil
      commentData.ups = nil
      self.init(data: commentData, api: rawMessage.redditAPI, typePrefix: "\(Comment.prefix)_")
    } else {
      throw RandomErr.oops
    }
  }
  
  static func initMultiple(datas: [ListingChild<T>], api: RedditAPI, parent: ObservableArray<GenericRedditEntity<T>>? = nil) -> [Comment] {
    let context = PersistenceController.shared.container.viewContext
    let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "CollapsedComment")
    if let results = (context.performAndWait { try? context.fetch(fetchRequest) as? [CollapsedComment] }) {
      return datas.compactMap { x in
        context.performAndWait {
          if let data = x.data {
            let isCollapsed = results.contains(where: { $0.commentID == data.id })
            let newComment = Comment.init(data: data, api: api, kind: x.kind, parent: parent)
            newComment.data?.collapsed = isCollapsed
            return newComment
          }
          return nil
        }
      }
    }
    return []
  }
  
  func toggleCollapsed(_ collapsed: Bool? = nil, optimistic: Bool = false) -> Void {
    if optimistic {
      let prev = data?.collapsed ?? false
      let new = collapsed == nil ? !prev : collapsed
      if prev != new { data?.collapsed = new }
    }
    let context = PersistenceController.shared.container.viewContext
    let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "CollapsedComment")
    do {
      let results = try context.fetch(fetchRequest) as! [CollapsedComment]
      let foundPost = results.first(where: { obj in obj.commentID == id })
      
      if let foundPost = foundPost {
        if collapsed == nil || collapsed == false {
            context.delete(foundPost)
          if !optimistic {
            data?.collapsed = false
          }
        }
      } else if collapsed == nil || collapsed == true {
        let newSeenPost = CollapsedComment(context: context)
        newSeenPost.commentID = id
        context.performAndWait {
          try? context.save()
        }
        if !optimistic {
          data?.collapsed = true
        }
      }
    } catch {
      print("Error fetching data from Core Data: \(error)")
    }
  }
  
  func loadChildren(parent: CommentParentElement, postFullname: String) async {
    if let kind = kind, kind == "more", let data = data, let count = data.count, let parent_id = data.parent_id, let childrenIDS = data.children {
      var actualID = id
      if actualID.hasSuffix("-more") {
        actualID.removeLast(5)
      }
      
      let childrensLimit = 25
      
      if let children = await redditAPI.fetchMoreReplies(comments: count > 0 ? Array(childrenIDS.prefix(childrensLimit)) : [String(parent_id.dropFirst(3))], moreID: actualID, postFullname: postFullname, dropFirst: count == 0) {
                
        let parentID = data.parent_id ?? ""
//        switch parent {
//        case .comment(let comment):
//          if let name = comment.data?.parent_id ?? comment.data?.name {
//              parentID = name
//          }
//        case .post(_):
//          if let postID = children[0].data?.link_id {
//            parentID = postID
//          }
//        }
        
        let loadedComments: [Comment] = nestComments(children, parentID: parentID, api: redditAPI)

        Task(priority: .background) { [loadedComments] in
          await redditAPI.updateAvatarURLCacheFromComments(comments: loadedComments)
        }
        await MainActor.run { [loadedComments] in
          switch parent {
          case .comment(let comment):
            if let index = comment.childrenWinston.data.firstIndex(where: { $0.id == id }) {
              withAnimation {
                if (self.data?.children?.count ?? 0) <= 25 {
                  comment.childrenWinston.data.remove(at: index)
                } else {
                  self.data?.children?.removeFirst(childrensLimit)
                  if let _ = self.data?.count {
                    self.data?.count! -= children.count
                  }
                }
                comment.childrenWinston.data.insert(contentsOf: loadedComments, at: index)
              }
            }
          case .post(let postArr):
            if let index = postArr.data.firstIndex(where: { $0.id == id }) {
              withAnimation {
                if (self.data?.children?.count ?? 0) <= 25 {
                  postArr.data.remove(at: index)
                } else {
                  self.data?.children?.removeFirst(childrensLimit)
                  if let _ = self.data?.count {
                    self.data?.count! -= children.count
                  }
                }
                postArr.data.insert(contentsOf: loadedComments, at: index)
              }
            }
          }
        }
      }
    }
  }
  
  func reply(_ text: String) async -> Bool {
    if let fullname = data?.name {
      let result = await redditAPI.newReply(text, fullname) ?? false
      if result, let data = data {
        var newComment = CommentData(id: UUID().uuidString)
        newComment.subreddit_id = data.subreddit_id
        newComment.subreddit = data.subreddit
        newComment.likes = true
        newComment.saved = false
        newComment.archived = false
        newComment.count = 0
        newComment.author = redditAPI.me?.data?.name ?? ""
        newComment.created_utc = nil
        newComment.send_replies = nil
        newComment.parent_id = id
        newComment.score = nil
        newComment.author_fullname = "t2_\(redditAPI.me?.data?.id ?? "")"
        newComment.approved_by = nil
        newComment.mod_note = nil
        newComment.collapsed = nil
        newComment.body = text
        newComment.top_awarded_type = nil
        newComment.name = nil
        newComment.is_submitter = nil
        newComment.downs = 0
        newComment.children = nil
        newComment.body_html = nil
        newComment.permalink = nil
        newComment.created = Double(Int(Date().timeIntervalSince1970))
        newComment.link_id = data.link_id
        newComment.link_title = data.link_title
        newComment.subreddit_name_prefixed = data.subreddit_name_prefixed
        newComment.depth = (data.depth ?? 0) + 1
        newComment.author_flair_background_color = nil
        newComment.collapsed_because_crowd_control = nil
        newComment.mod_reports = nil
        newComment.num_reports = nil
        newComment.ups = 1
        await MainActor.run { [newComment] in
          withAnimation {
            childrenWinston.data.append(Comment(data: newComment, api: self.redditAPI))
          }
        }
      }
      return result
    }
    return false
  }
  
  func saveToggle() async -> Bool {
    if let data = data, let fullname = data.name {
      let prev = data.saved ?? false
      await MainActor.run {
        withAnimation {
          self.data?.saved = !prev
        }
      }
      let success = await redditAPI.save(!prev, id: fullname)
      if !(success ?? false) {
        await MainActor.run {
          withAnimation {
            self.data?.saved = prev
          }
        }
        return false
      }
      return true
    }
    return false
  }
  
  func vote(action: RedditAPI.VoteAction) async -> Bool? {
    let oldLikes = data?.likes
    let oldUps = data?.ups ?? 0
    var newAction = action
    newAction = action.boolVersion() == oldLikes ? .none : action
    await MainActor.run { [newAction] in
      withAnimation {
        data?.likes = newAction.boolVersion()
        data?.ups = oldUps + (action.boolVersion() == oldLikes ? oldLikes == nil ? 0 : -action.rawValue : action.rawValue * (oldLikes == nil ? 1 : 2))
      }
    }
    let result = await redditAPI.vote(newAction, id: "\(typePrefix ?? "")\(id)")
    if result == nil || !result! {
      await MainActor.run { [oldLikes] in
        withAnimation {
          data?.likes = oldLikes
          data?.ups = oldUps
        }
      }
    }
    return result
  }
  
  func edit(_ newBody: String) async -> Bool? {
    if let data = data, let name = data.name {
      //      let oldBody = data.body
      //      await MainActor.run {
      //        withAnimation {
      //          self.data?.body = newBody
      //        }
      //      }
      let result = await redditAPI.edit(fullname: name, newText: newBody)
      if (result ?? false) {
        await MainActor.run {
          withAnimation {
            self.data?.body = newBody
          }
        }
      }
      //      if result == nil || !result! {
      //        await MainActor.run {
      //          withAnimation {
      //            self.data?.body = oldBody
      //          }
      //        }
      //      }
      return result
    }
    return nil
  }
  
  func del() async -> Bool? {
    if let name = data?.name {
      let result = await redditAPI.delete(fullname: name)
      if (result ?? false) {
        if let parentWinston = self.parentWinston {
          let newParent = parentWinston.data.filter { $0.id != id }
          await MainActor.run {
            withAnimation {
              self.parentWinston?.data = newParent
            }
          }
        }
      }
      return result
    }
    return nil
  }
}

struct CommentData: GenericRedditEntityDataType {
  
  init(id: String) {
    self.id = id
  }
  
  var subreddit_id: String?
  //  let approved_at_utc: Int?
  //  let author_is_blocked: Bool?
  //  let comment_type: String?
  //  let awarders: [String]?
  //  let mod_reason_by: String?
  //  let banned_by: String?
  //  let author_flair_type: String?
  //  let total_awards_received: Int?
  var subreddit: String?
  //  let author_flair_template_id: String?
  var likes: Bool?
  var replies: Either<String, Listing<CommentData>>?
  //  let user_reports: [String]?
  var saved: Bool?
  var id: String
  //  let banned_at_utc: String?
  //  let mod_reason_title: String?
  //  let gilded: Int?
  var archived: Bool?
  //  let collapsed_reason_code: String?
  //  let no_follow: Bool?
  var count: Int?
  var author: String?
  //  let can_mod_post: Bool?
  var created_utc: Double?
  var send_replies: Bool?
  var parent_id: String?
  var score: Int?
  var author_fullname: String?
  var approved_by: String?
  var mod_note: String?
  //  let all_awardings: [String]?
  var collapsed: Bool?
  var body: String?
  var winstonBodyAttrEncoded: String?
  //  let edited: Bool?
  var top_awarded_type: String?
  //  let author_flair_css_class: String?
  var name: String?
  var is_submitter: Bool?
  var downs: Int?
  //  let author_flair_richtext: [String]?
  //  let author_patreon_flair: Bool?
  var children: [String]?
  var body_html: String?
  //  let removal_reason: String?
  //  let collapsed_reason: String?
  //  let distinguished: String?
  //  let associated_award: String?
  //  let stickied: Bool?
  //  let author_premium: Bool?
  //  let can_gild: Bool?
  //  let gildings: [String: String]?
  //  let unrepliable_reason: String?
  //  let author_flair_text_color: String?
  //  let score_hidden: Bool?
    var permalink: String?
  //  let subreddit_type: String?
  //  let locked: Bool?
  //  let report_reasons: String?
  var created: Double?
  //  let author_flair_text: String?
  //  let treatment_tags: [String]?
  var link_id: String?
  var link_title: String?
  var subreddit_name_prefixed: String?
  //  let controversiality: Int?
  var depth: Int?
  var author_flair_background_color: String?
  var collapsed_because_crowd_control: String?
  var mod_reports: [String]?
  var num_reports: Int?
  var ups: Int?
  var winstonSelecting: Bool? = false
}

// Encode AttributedString manually
//func encode(to encoder: Encoder) throws {
//   var container = encoder.container(keyedBy: CodingKeys.self)
//
//   // ...encode all other properties...
//
//   if let winstonBodyAttr = winstonBodyAttr {
//       try container.encode(winstonBodyAttr.markdownRepresentation, forKey: .winstonBodyAttr)
//   }
//}

struct Gildings: Codable {
}

struct CommentSort: Codable, Identifiable {
  var icon: String
  var value: String
  var id: String {
    value
  }
}

enum CommentSortOption: Codable, CaseIterable, Identifiable, Defaults.Serializable {
  var id: String {
    self.rawVal.id
  }
  
  case confidence
  case new
  case top
  case controversial
  case old
  case random
  case qa
  case live
  
  var rawVal: SubListingSort {
    switch self {
    case .confidence:
      return SubListingSort(icon: "flame", value: "confidence")
    case .new:
      return SubListingSort(icon: "newspaper", value: "new")
    case .top:
      return SubListingSort(icon: "trophy", value: "top")
    case .controversial:
      return SubListingSort(icon: "figure.fencing", value: "controversial")
    case .old:
      return SubListingSort(icon: "clock.arrow.circlepath", value: "old")
    case .random:
      return SubListingSort(icon: "dice", value: "random")
    case .qa:
      return SubListingSort(icon: "bubble.left.and.bubble.right", value: "qa")
    case .live:
      return SubListingSort(icon: "dot.radiowaves.left.and.right", value: "live")
    }
  }
}
