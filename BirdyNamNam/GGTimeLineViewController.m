//
//  GGTimeLineViewController.m
//  BirdyNamNam
//
//  Created by Gwenn on 22/02/13.
//  Copyright (c) 2013 Free. All rights reserved.
//

#import "GGTimeLineViewController.h"
#import "GGAppDelegate.h"
#import "SVProgressHUD.h"
#import "Tweet.h"
#import "GGDetailTweetViewController.h"

@interface GGTimeLineViewController ()
{
    BOOL _hasCache;
}

@property BOOL _isFetchingTweets;
@property (strong,nonatomic) NSString *_oldestTweetID, *_newestTweetID;
@property UIView *_refreshHeaderView;
@property UILabel *_refreshLabel;
@property UIActivityIndicatorView *_spinner;

@end

#define REFRESH_HEADER_HEIGHT 52.0f

@implementation GGTimeLineViewController

@synthesize twitterEngine, imageCache, moc, fetcher = _fetcher;
@synthesize _oldestTweetID, _newestTweetID, _refreshHeaderView, _refreshLabel, _spinner;

// getter fetcher
- (NSFetchedResultsController*) fetcher
{
    if (_fetcher != nil)
    {
        return _fetcher;
    }
    
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Tweet"];
    request.fetchBatchSize = 20;
    //request.fetchLimit = 50;
    request.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"tweetid" ascending:NO] ];
    
    
    _fetcher = [[NSFetchedResultsController alloc] initWithFetchRequest:request managedObjectContext:self.moc sectionNameKeyPath:nil cacheName:@"tweetCache"];
    self.fetcher = _fetcher;
    
    _fetcher.delegate = self;
    
    return _fetcher;
}

- (id)initWithStyle:(UITableViewStyle)style
{
    self = [super initWithStyle:style];
    if (self) {
        // Custom initialization
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    // coredata
    self.moc = [(GGAppDelegate*)[[UIApplication sharedApplication] delegate] managedObjectContext];
    
    [self _addPullToRefreshHeader];
    
    self.title = @"My Timeline";
    
    imageCache = [[NSCache alloc] init];
    
    self.twitterEngine = [FHSTwitterEngine sharedTwitterEngine];
    
    NSError *error;
    if ( ![self.fetcher performFetch:&error] )
    {
        NSLog(@"Error fetching results %@, %@",error,error.userInfo);
    }
    
    [self _getOldestTweetID];
    [self _getNewestTweetID];
    
    if (self._oldestTweetID)
    {
        _hasCache = YES;
    }
    else
    {
        _hasCache = NO;
        [self _fetchTweetsBeforeID:nil orSinceID:nil];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self _loadAuthorImageForVisibleRows];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    // Return the number of sections.
    return self.fetcher.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    // Return the number of rows in the section.
    id <NSFetchedResultsSectionInfo> sectionInfo = [self.fetcher.sections objectAtIndex:section];
    return [sectionInfo numberOfObjects] + 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell;
    
    if (indexPath.row == self.fetcher.fetchedObjects.count)
    {
        cell = [tableView dequeueReusableCellWithIdentifier:@"MoreCell"];
        if (cell == nil)
        {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"MoreCell"];
        }
        return cell;
    }
    
    static NSString *CellIdentifier = @"TweetCell";
    cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil)
    {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:CellIdentifier];
    }
    
    [self configureCell:cell cellForRowAtIndexPath:indexPath];

    return cell;

}

- (void)configureCell:(UITableViewCell *)cell cellForRowAtIndexPath:(NSIndexPath *)indexPath
{   
    Tweet *tweet = [self.fetcher objectAtIndexPath:indexPath];
    
    NSString *text = [tweet.infos objectForKey:@"text"];
    NSString *authorName = [[tweet.infos objectForKey:@"user"] objectForKey:@"name"];
    
    
    UILabel *authorNameLabel = (UILabel*)[cell viewWithTag:2];
    authorNameLabel.text = authorName;
    
    
    UILabel *textLabel = (UILabel*)[cell viewWithTag:3];
    CGRect rect = textLabel.frame;
    rect.size.width = self.tableView.frame.size.width - 90;
    textLabel.frame = rect;
    textLabel.font = [UIFont systemFontOfSize:12.0];
    textLabel.text = text;
    [textLabel sizeToFit];
    //[textLabel sizeToFitFixedWidth]; // resize label
    
    UIImageView *authorImageView = (UIImageView*)[cell viewWithTag:1];
    // image, cache or not cache ?
    NSString *authorID = [[tweet.infos objectForKey:@"user"] objectForKey:@"id_str"];

    dispatch_async(GCDBackgroundThread, ^{
        @autoreleasepool {
            NSData *data = [imageCache objectForKey:authorID];
            dispatch_sync(GCDMainThread, ^{
                @autoreleasepool
                {
                    if (data)
                    {
                        authorImageView.image = [UIImage imageWithData: data ];
                    }
                    else
                    {
                        authorImageView.image = [UIImage imageNamed:@"Placeholder.png"];
                    }
                }});
        }});
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.row == self.fetcher.fetchedObjects.count)
    {
        return tableView.rowHeight;
    }
    
    Tweet *tweet = [self.fetcher objectAtIndexPath:indexPath];
    NSString *text = [tweet.infos objectForKey:@"text"];
    CGSize textSize = [text sizeWithFont:[UIFont systemFontOfSize:12] constrainedToSize: CGSizeMake( self.tableView.frame.size.width - 90,CGFLOAT_MAX )];
    
    return MAX(textSize.height + 40,tableView.rowHeight);
    
}

- (void)_saveTweetsinArray:(NSArray*)tweets
{
    NSError *error;
    
    NSLog(@"tweets count to insert %d",tweets.count);
    
    // save in core data
    for (NSDictionary *tweet in tweets)
    {
        Tweet *tweetEntity = [NSEntityDescription insertNewObjectForEntityForName:@"Tweet" inManagedObjectContext:moc];
        NSData *json = [NSJSONSerialization dataWithJSONObject:tweet options:NSJSONWritingPrettyPrinted error:&error];
        if (json != nil)
        {
            NSString *jsonstr = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
            tweetEntity.json = jsonstr;
            
            //NSLog(@"json str %d entity json %d %@",jsonstr.length,tweetEntity.json.length,jsonstr);
            
            tweetEntity.tweetid = [tweet objectForKey:@"id_str"];
            // save json as nsdictionnary
            //NSData *data = [jsonstr dataUsingEncoding:NSUTF8StringEncoding];
            //tweetEntity.infos = removeNull([NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil]);
        }
        else
        {
            NSLog(@"Error create JSON Frow Tweet %@ , %@",error,error.userInfo);
        }
    }
    
    // save
    if (![moc save:&error])
    {
        NSLog(@"Error saving Tweet %@ , %@",error,error.userInfo);
    }
    
    
}

- (void)_fetchTweetsBeforeID:(NSString *)beforeID orSinceID:(NSString *) sinceID
{
    self._isFetchingTweets = YES;
    
    [SVProgressHUD show];
    
    
    dispatch_async(GCDBackgroundThread, ^{
        @autoreleasepool {
            
            [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
            
            id twitterCallBack;
            __block NSMutableArray *newTweets = nil;
            
            if (beforeID == nil && sinceID == nil) // timeline for the first time
            {
                twitterCallBack = [self.twitterEngine getHomeTimelineBeforeID:beforeID count:50];
                
            }
            else if (sinceID != nil) // add new tweets
            {
                twitterCallBack = [self.twitterEngine getHomeTimelineSinceID:sinceID count:50];
                //[self _saveTweetsinArray:beforeTweets];
            }
            else if (beforeID != nil) // old tweets
            {
                twitterCallBack = [self.twitterEngine getHomeTimelineBeforeID:beforeID count:5];
                // remove first object because of incluse request, last tweet included
                if ([twitterCallBack isKindOfClass: [NSDictionary class]])
                {
                    newTweets = [twitterCallBack mutableCopy];
                    if (newTweets.count > 1) [newTweets removeObjectAtIndex:0];
                }
            }
            
            dispatch_sync(GCDMainThread, ^{
                @autoreleasepool
                {
                    /*if (beforeTweets && beforeTweets.count > 0)
                    {
                        [self.tableView beginUpdates];
                        NSRange range = NSMakeRange(0, beforeTweets.count);
                        NSMutableArray *rangeArray = [NSMutableArray arrayWithCapacity:range.length];
                        for (int i = range.location ; i < (range.location + range.length) ; i++)
                        {
                            [rangeArray addObject: [NSIndexPath indexPathForRow:i inSection:0] ];
                        }
                        [self.tweets insertObjects:beforeTweets atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, beforeTweets.count)]];
                        [self.tableView insertRowsAtIndexPaths:rangeArray withRowAnimation:UITableViewRowAnimationFade];
                        [self.tableView endUpdates];
                    }
                    else if (moreTweets && moreTweets.count > 0)
                    {
                        [self.tableView beginUpdates];
                        NSRange range = NSMakeRange(self.tweets.count-2, moreTweets.count - 1);
                        NSMutableArray *rangeArray = [NSMutableArray arrayWithCapacity:range.length];
                        for (int i = range.location ; i < (range.location + range.length) ; i++)
                        {
                            [rangeArray addObject: [NSIndexPath indexPathForRow:i inSection:0] ];
                        }
                        
                        [self.tweets addObjectsFromArray: [moreTweets subarrayWithRange:NSMakeRange(1, moreTweets.count-1)]];
                        [self.tableView insertRowsAtIndexPaths:  rangeArray  withRowAnimation:UITableViewRowAnimationFade];
                        [self.tableView endUpdates];
                    }*/
                    
                    if ([twitterCallBack isKindOfClass: [NSError class]])
                    {
                        [SVProgressHUD showSuccessWithStatus:@"Failed !"];
                        NSError *error = twitterCallBack;
                        NSLog(@"Fetching Tweets failed %@, %@", error.description, error.userInfo );
                    }
                    else
                    {
                        newTweets = twitterCallBack;
                        
                        [self _saveTweetsinArray:newTweets];
                        
                        if (_hasCache == NO)
                        {
                            _hasCache = YES;
                            [self.tableView reloadData];
                        }
                        
                        [self _loadAuthorImageForVisibleRows];
                        
                        [self _getOldestTweetID];
                        [self _getNewestTweetID];
                        
                        [SVProgressHUD showSuccessWithStatus:@"Done !"];
                    }
                    
                    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
                    self._isFetchingTweets = NO;
                    self.tableView.contentInset = UIEdgeInsetsZero;
                    [_spinner stopAnimating];
                }
            });
        }
    });
}

- (void)_getOldestTweetID
{
    NSError *error;
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Tweet"];
    request.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"tweetid" ascending:YES] ];
    request.fetchLimit = 1;
    NSArray *results = [self.moc executeFetchRequest:request error:&error];
    if (results.lastObject)
    {
        self._oldestTweetID = ( (Tweet*)results.lastObject ).tweetid;
    }
}

- (void)_getNewestTweetID
{
    NSError *error;
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Tweet"];
    request.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"tweetid" ascending:NO] ];
    request.fetchLimit = 1;
    NSArray *results = [self.moc executeFetchRequest:request error:&error];
    if (results.lastObject)
    {
        self._newestTweetID = ( (Tweet*) [results objectAtIndex:0] ).tweetid;
    }
}

- (void)_addPullToRefreshHeader
{
    _refreshHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0 - REFRESH_HEADER_HEIGHT, self.tableView.bounds.size.width, REFRESH_HEADER_HEIGHT)];
    _refreshHeaderView.backgroundColor = [UIColor clearColor];
    
    _refreshLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, REFRESH_HEADER_HEIGHT)];
    _refreshLabel.backgroundColor = [UIColor clearColor];
    _refreshLabel.font = [UIFont boldSystemFontOfSize:12.0];
    _refreshLabel.textAlignment = NSTextAlignmentCenter;
    _refreshLabel.text = @"Pull to Refresh";
        
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    _spinner.frame = CGRectMake(floorf(floorf(REFRESH_HEADER_HEIGHT - 20) / 2), floorf((REFRESH_HEADER_HEIGHT - 20) / 2), 20, 20);
    _spinner.hidesWhenStopped = YES;
    
    [_refreshHeaderView addSubview:_refreshLabel];
    [_refreshHeaderView addSubview:_spinner];
    [self.tableView addSubview:_refreshHeaderView];
}

- (void)_loadAuthorImageForVisibleRows
{
    if (self.fetcher.fetchedObjects.count > 0)
    {   
        NSArray *visiblePaths = [self.tableView indexPathsForVisibleRows];
        
        for (NSIndexPath *indexPath in visiblePaths)
        {
            if (indexPath.row >= self.fetcher.fetchedObjects.count) return;
            
            Tweet *tweet = [self.fetcher objectAtIndexPath:indexPath];
            
            UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
            UIImageView *authorImageView = (UIImageView*)[cell viewWithTag:1];
            
            NSString *imageUrl = [[tweet.infos objectForKey:@"user"] objectForKey:@"profile_image_url"];
            if (imageUrl != nil)
            {
                NSString *extension = [@"." stringByAppendingString:[imageUrl pathExtension]];
                NSString *authorID = [[tweet.infos objectForKey:@"user"] objectForKey:@"id_str"];
                NSString *path = [[NSTemporaryDirectory() stringByAppendingPathComponent:authorID] stringByAppendingString:extension];
                
                // ram
                NSData *data = [imageCache objectForKey:authorID];
                if (data != nil)
                {
                    authorImageView.image = [UIImage imageWithData:data];
                    continue;
                }
                
                // disk
                if ( [[NSFileManager defaultManager] fileExistsAtPath: path] )
                {
                    // put in nscache
                    NSData *data = [NSData dataWithContentsOfFile:path];
                    [imageCache setObject:data forKey:authorID];
                    // add image
                    authorImageView.image = [UIImage imageWithData:data];
                    continue;
                }
                
                // load
                dispatch_async(GCDBackgroundThread, ^{
                    @autoreleasepool
                    {
                        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:imageUrl]];
                        
                        dispatch_sync(GCDMainThread, ^{
                            @autoreleasepool
                            {
                                // disk + cache image
                                if (data != nil)
                                {
                                    [data writeToFile:path atomically:NO];
                                    
                                    [imageCache setObject:data forKey:authorID];
                                    // add image
                                    authorImageView.image = [UIImage imageWithData:data];
                                }
                            }
                        });
                    }
                });
            }
        }
    }
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender
{
    if ([segue.identifier isEqualToString:@"showDetailTweetSegue"])
    {
        GGDetailTweetViewController *detailTweetViewController = (GGDetailTweetViewController*)segue.destinationViewController;
        
        UITableViewCell *cell = (UITableViewCell*)sender;
        NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
        Tweet *tweet = [self.fetcher objectAtIndexPath:indexPath];
        
        detailTweetViewController.managedObjectId = tweet.objectID;
        detailTweetViewController.imageCache = self.imageCache;
    }
}

#pragma mark - UI ScrollVIew delegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    CGFloat offsetY = self.tableView.contentOffset.y;
    CGFloat contentHeight = self.tableView.contentSize.height - self.tableView.bounds.size.height;
    
    // pull to refresh
    if (self._isFetchingTweets == NO)
    {
        if (offsetY < -REFRESH_HEADER_HEIGHT)
        {
            _refreshLabel.text = @"Release to Refresh";
        }
        else
        {
            _refreshLabel.text = @"Pull to Refresh";
        }
    }    
    // load more
    if (offsetY >= contentHeight && self._isFetchingTweets == NO)
    {
        NSLog(@"load more !");
        [self _fetchTweetsBeforeID:self._oldestTweetID orSinceID:nil];
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    // pull to refresh
    CGFloat offsetY = self.tableView.contentOffset.y;
    if (offsetY < -REFRESH_HEADER_HEIGHT && self._isFetchingTweets == NO)
    {
        self.tableView.contentInset = UIEdgeInsetsMake(-offsetY, 0, 0, 0);
        [_spinner startAnimating];
        [self _fetchTweetsBeforeID:nil orSinceID:_newestTweetID];
    }
    
    if (!decelerate)
    {
        [self _loadAuthorImageForVisibleRows];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    [self _loadAuthorImageForVisibleRows];
}

#pragma mark - NsFetchedResultsController delegate

/*
 NSFetchedResultsController delegate methods to respond to additions, removals and so on.
 */

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller
{
    // The fetch controller is about to start sending change notifications, so prepare the table view for updates.
    //self.tableView.scrollEnabled = NO;
    [self.tableView beginUpdates];
}


- (void)controller:(NSFetchedResultsController *)controller didChangeObject:(id)anObject atIndexPath:(NSIndexPath *)indexPath forChangeType:(NSFetchedResultsChangeType)type newIndexPath:(NSIndexPath *)newIndexPath
{
    UITableView *tableView = self.tableView;
    
    switch(type) {
            
        case NSFetchedResultsChangeInsert:
            [tableView insertRowsAtIndexPaths:[NSArray arrayWithObject:newIndexPath] withRowAnimation:UITableViewRowAnimationFade];
            break;
            
        case NSFetchedResultsChangeDelete:
            [tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
            break;
            
        case NSFetchedResultsChangeUpdate:
            //[self.tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationNone];
            [self configureCell:[tableView cellForRowAtIndexPath:indexPath] cellForRowAtIndexPath:indexPath];
            break;
            
        case NSFetchedResultsChangeMove:
            [tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
            [tableView insertRowsAtIndexPaths:[NSArray arrayWithObject:newIndexPath] withRowAnimation:UITableViewRowAnimationFade];
            break;
    }
}


- (void)controller:(NSFetchedResultsController *)controller didChangeSection:(id <NSFetchedResultsSectionInfo>)sectionInfo atIndex:(NSUInteger)sectionIndex forChangeType:(NSFetchedResultsChangeType)type
{
    switch(type) {
            
        case NSFetchedResultsChangeInsert:
            [self.tableView insertSections:[NSIndexSet indexSetWithIndex:sectionIndex] withRowAnimation:UITableViewRowAnimationFade];
            break;
            
        case NSFetchedResultsChangeDelete:
            [self.tableView deleteSections:[NSIndexSet indexSetWithIndex:sectionIndex] withRowAnimation:UITableViewRowAnimationFade];
            break;
    }
}


- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller
{
    // The fetch controller has sent all current change notifications, so tell the table view to process all updates.
    [self.tableView endUpdates];
    //self.tableView.scrollEnabled = YES;
}

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    // Navigation logic may go here. Create and push another view controller.
    /*
     <#DetailViewController#> *detailViewController = [[<#DetailViewController#> alloc] initWithNibName:@"<#Nib name#>" bundle:nil];
     // ...
     // Pass the selected object to the new view controller.
     [self.navigationController pushViewController:detailViewController animated:YES];
     */
}

- (void)viewWillAppear
{
    //[self.tableView reloadData];
}


- (void)viewDidUnload
{
    self.fetcher = nil;
}



@end
