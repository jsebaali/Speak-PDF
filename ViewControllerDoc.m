//
//  ViewControllerDoc.m
//  Demo 1.1
//
//  Created by Jana Sebaali on 4/20/20.
//  Copyright © 2020 Jana Sebaali. All rights reserved.
//

#import "ViewControllerDoc.h"
#import <PDFNet/PDFNet.h>
#import <Tools/Tools.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <Foundation/Foundation.h>
#include <math.h>

@interface ViewControllerDoc ()

@end

@implementation ViewControllerDoc

@synthesize pdfURL;
@synthesize speechRecognizer;
@synthesize recognitionRequest;
@synthesize recognitionTask;
@synthesize audioEngine;
@synthesize pdfViewCtrl;


int numberOfPages;
int totalElemCount;


NSMutableDictionary *lastSectionBookmarksOnPage; // for each page number, stores the last section bookmark
NSMutableDictionary *references; // for each reference number, stores the reference
PTDocumentViewController *documentController; // used to view the document
NSMutableDictionary *textOnPage; // for each page, holds the text string
NSMutableDictionary *pageToRefLocations; // for each page, holds an array with ref locations in the text
NSMutableDictionary *pageLocationsToRef; // for each page and ref locatin, holds the reference(s)
NSMutableDictionary *numFiguresPerSection; // number of figures in section
AVSpeechSynthesizer *synthesizer; // used to read out text
AVSpeechSynthesizer *synthesizerReferences; // used to read out references
AVSpeechSynthesizer *synthesizerErrors; // used to read out errors
NSURL *pdfNSURL; // input url
NSUInteger textOffset = 0; // offset in the strin where the speech synthesizer started reading
UINavigationController *navigationControllerDoc; // used to view the documentController
NSString *totalCommands; // holds the audio input from user
AVAudioInputNode *inputNode;


bool requestedReferenceReading = false; // indicates if used "Read references" command
int currentViewPage; // current page number viewed on screen

 
// add two bookmarks for each element extracted, one within the document outline where the document is located and one at the end of the document outline. It takes in the pageNumber where the element was extracted from, the count which counts the total number of elements extracted, and the total numberOfPages of the doc.
static void AddBookmarks(int pageNumber, int numberOfPages, int figurePageNumber, PTPDFDoc *doc){
    NSString *bookmarkTitle;
    NSString *bookmarkTitle2;
    PTBookmark * currBookmark;
    PTBookmark * currBookmark2;
    PTBookmark * lastSectionBookmarkOnPage;
    NSUInteger bookmarkCount;
     
    // In order to add the bookmark element at the correct place in the outline, get the last bookmark on this pageNumber. If there is none, look in the previous pages for the last bookmark.
    bookmarkCount = [lastSectionBookmarksOnPage count];
    lastSectionBookmarkOnPage = lastSectionBookmarksOnPage[[@(pageNumber) stringValue]];
    
    // if an outline exists, get the lastBookmark
    if (bookmarkCount != 0){
    int pageNumberPrev = pageNumber;
        while (!lastSectionBookmarkOnPage.IsValid){
          //  NSLog(@"%@", @(pageNumberPrev));
            pageNumberPrev--;
            lastSectionBookmarkOnPage = lastSectionBookmarksOnPage[[@(pageNumberPrev) stringValue]];
         }
    }
    
    // create the bookmark titles
    NSString *sectionTitle = [lastSectionBookmarkOnPage GetTitle];
    char firstChar = [sectionTitle characterAtIndex:0];
    char secondChar = [sectionTitle characterAtIndex:1];
    
    if (sectionTitle == nil){
        sectionTitle =@"no outline";
    }
    
    NSInteger countTrue = 1;
    id countID = [numFiguresPerSection objectForKey:sectionTitle];
    if (countID != nil){
        countTrue = [countID integerValue];
        countTrue++;
    }
    [numFiguresPerSection setObject:@(countTrue) forKey:sectionTitle];
    
   
    if (isdigit((int)secondChar)){
        bookmarkTitle = [NSString stringWithFormat:@"Section %c%c Figure %@", firstChar,secondChar, @(countTrue)];
    }else{
        bookmarkTitle = [NSString stringWithFormat:@"Section %c Figure %@", firstChar, @(countTrue)];
    }
        bookmarkTitle2 = [NSString stringWithFormat:@"Figure %@", @(countTrue)];
        
    // create the bookmarks and set their actions to go to the page where the element is placed
    currBookmark = [PTBookmark Create: doc in_title: bookmarkTitle];
    [currBookmark SetAction: [PTAction CreateGoto: [PTDestination CreateFit: [doc GetPage: figurePageNumber]]]];
        
    currBookmark2 = [PTBookmark Create: doc in_title: bookmarkTitle2];
    [currBookmark2 SetAction: [PTAction CreateGoto: [PTDestination CreateFit: [doc GetPage: figurePageNumber]]]];
     
    // if the pdf contains an outline to its sections, add a bookmark to the page where the figure/table was extracted from
    if (bookmarkCount!= 0) {
        [lastSectionBookmarkOnPage AddChildWithBookmark:currBookmark2];
        // add the second bookmark to the added page at the end of the document
        [doc AddRootBookmark: currBookmark];
         
    } else{
        [doc AddRootBookmark: currBookmark2];
    }
    
}

// Gets the element, transforms it and writes it to a new page added at the end of the doc
static void TransformElement(PTElement *element, PTPage *newPage, PTPDFDoc *doc){
    
    PTElementWriter *writerElem = [[PTElementWriter alloc]init];
    newPage = [doc PageCreate: [[PTPDFRect alloc] initWithX1: 0 y1: 0 x2: 900 y2: 900]]; // 612 794
     [writerElem WriterBeginWithPage: newPage placement:  e_ptoverlay page_coord_sys: NO compress: NO resources: NULL];
    
        PTPDFRect *rect = [element GetBBox];
        double width = [rect GetX2]-[rect GetX1];
        double height = [rect GetY2]  - [rect GetY1];
        NSLog(@"w %f h %f", width, height);
        double xScaling = width/700;
        double yScaling = height/600;
    
       PTGState *gstate = [element GetGState];
       [gstate SetTransform:xScaling b:0 c:0 d:yScaling h:50 v:50];
       [writerElem WritePlacedElement: element];
       [writerElem End];
       [doc PagePushBack:newPage];
    
}


// adds a hyperlink from the page where the object was described in to the page where the object is now
static void AddHyperlinkToFigure(PTElement *elem, int pageNumber,int figurePageNumber, PTPDFDoc *doc){
   
     PTPage *figurePageExtraction = [doc GetPage: pageNumber];
    
    // get matrix of elem
    PTMatrix2D *matrix = [elem GetCTM];

    // set the action of the inter-document hyperlink to go to the target page
    PTAction *goto_page_pageNumber = [PTAction CreateGoto: [PTDestination CreateFitH: [doc GetPage:figurePageNumber] top: 0]];
    PTLink *link = [PTLink CreateWithAction: [doc GetSDFDoc] pos: [[PTPDFRect alloc] initWithX1: [matrix getM_h] y1: [matrix getM_v] x2: ([matrix getM_h] + 50) y2: ([matrix getM_v]+50)] action: goto_page_pageNumber];

    // Set the annotation border width to 3 points...
    PTBorderStyle *border_style = [[PTBorderStyle alloc] initWithS: e_ptsolid b_width: 3 b_hr:0 b_vr:0];
    [link SetBorderStyle:border_style oldStyleOnly:FALSE];
    [link SetColor: [[PTColorPt alloc] initWithX: 0 y:0 z:1 w:0] numcomp: 3];
    [figurePageExtraction AnnotPushBack:link];
 

}

// adds a hyperlink to the added page that links back to the page where the object was described in
static void AddHyperlinkBack(int pageNumber,int figurePageNumber, PTPDFDoc *doc){
   
    PTElementWriter *writer = [[PTElementWriter alloc]init];
    PTPage *page = [doc GetPage:figurePageNumber];
       
    [writer WriterBeginWithPage: page placement:  e_ptoverlay page_coord_sys: YES compress: YES resources: NULL];
   
    // Create an element builder
    PTElementBuilder *eb = [[PTElementBuilder alloc] init];
    // the first element to write is a  textbegin
    PTElement *element = [eb CreateTextBeginWithFont: [PTFont Create: [doc GetSDFDoc] type: e_pttimes_roman embed: NO] font_sz: 9];
    [writer WriteElement: element];
    // add the text
    element = [eb CreateTextRun: @"Exit"];
    [element SetTextMatrix: 10 b: 0 c: 0 d: 10 h: 90 v: 800];
    [[element GetGState] SetLeading: 15]; // Set the spacing between lines
    [writer WriteElement: element];
    // Finish the block of text
    [writer WriteElement: [eb CreateTextEnd]];
    [writer End];
    
    
    // set the action of the inter-document hyperlink to go to the target page
    PTAction *goto_page_pageNumber = [PTAction CreateGoto: [PTDestination CreateFitH: [doc GetPage:pageNumber] top: 0]];
    PTLink *link = [PTLink CreateWithAction: [doc GetSDFDoc] pos: [[PTPDFRect alloc] initWithX1: 85 y1: 780 x2: 270 y2: 880] action: goto_page_pageNumber];

    // Set the annotation border width to 3 points...
    PTBorderStyle *border_style = [[PTBorderStyle alloc] initWithS: e_ptsolid b_width: 3 b_hr:0 b_vr:0];
    [link SetBorderStyle:border_style oldStyleOnly:FALSE];
    [link SetColor: [[PTColorPt alloc] initWithX: 0 y:0 z:1 w:0] numcomp: 3];
  
  
    PTPage *figurePage = [doc GetPage: figurePageNumber];
    [figurePage AnnotPushBack:link];
 

}
// Takes in the reference string found in the text e.g. [1], its location, gets the reference numbers, and creates a pop-up note that includes the references for the extracted reference numbers
static void addReferencePopUp(NSString *ref,  PTPDFRect *location, PTPDFDoc *doc, int pageNum){

    UniChar utf8chardash = 0x2013;
    NSString* dash = [NSString stringWithCharacters:&utf8chardash length:1];

    NSRange match = [ref rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]];
    if (match.location != NSNotFound){
        return;
    }
    
    // extract the numbers
    // remove opening bracket
    NSRange range = [ref rangeOfString:@"["];
    NSInteger openingBracketIndex = range.location;
     ref = [ref substringFromIndex:openingBracketIndex + 1];
    // remove closing bracket and any other char after it
    range = [ref rangeOfString:@"]"];
    NSInteger closingBracketIndex = range.location;
    ref = [ref substringToIndex:closingBracketIndex];
 
    
    // if ref has only 2 characters or less, then ref contains only one reference number
    if ([ref length] <= 2){
     // create a text annotation next to the location where the reference number e.g [3] was found
        PTText *txt = [PTText Create:[doc GetSDFDoc]
        pos:[[PTPDFRect alloc] initWithX1:[location GetX1] + 5 y1:[location GetY1] x2:[location GetX2] + 5 y2:[location GetY2]]];
        PTPage *page = [doc GetPage:pageNum];
        // set the contents of the popup as the reference
        [txt SetContents:[references objectForKey:ref]];
        [txt SetColor:[[PTColorPt alloc] initWithX:0 y:1 z:0 w:0] numcomp:3];
        [page AnnotPushBack:txt];
    } else{
        // this is the case where ref is [3,5,7,8-12] or [8-12] or [3, 4, 6]
        
        // get the numbers seperated by a comma
        NSArray *numbers = [ref componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@","]];
        NSString *contents = @"";
        
        // if no numbers extracted, check if it is a range e.g. 15-20
        if ([numbers count] == 0){
            
            // dash represented by unichar \u201320
            numbers = [ref componentsSeparatedByCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"\u201320"]];

            // if a range is extracted, add the references to the contents string
            for (int i = (int)numbers[0]; i <= (int)numbers[1]; i++){
                 contents = [contents stringByAppendingString:[references objectForKey:[@(i) stringValue]]];
                contents = [contents stringByAppendingString:@"\n\n"];
            }
            
            // dash represented by unichar 0x2013
            numbers = [ref componentsSeparatedByCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:dash]];

           // if a range is extracted, add the references to the contents string
           for (int i = (int)numbers[0]; i <= (int)numbers[1]; i++){
                contents = [contents stringByAppendingString:[references objectForKey:[@(i) stringValue]]];
               contents = [contents stringByAppendingString:@"\n\n"];
           }

        }else {
        
            for (id num in numbers) {
            
            // check if one of the num is a range e.g. 15-20
            
            // check if a dash is represented by unicode \u201320
            NSRange range = [num rangeOfString:@"\u201320"];
            if (range.location != NSNotFound){
                // contains a range of numbers
                NSArray *numRange = [num componentsSeparatedByCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"\u201320"]];

                for (int i = (int)numRange[0]; i < (int)numRange[1]; i++){
                     contents = [contents stringByAppendingString:[references objectForKey:[@(i) stringValue]]];
                    contents = [contents stringByAppendingString:@"\n\n"];
                }
                
            } else if ([num containsString:dash]){
                NSArray *numRange = [num componentsSeparatedByCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:dash]];

                for (long i = [((NSNumber*)[numRange objectAtIndex:0]) intValue]; i <= [((NSNumber*)[numRange objectAtIndex:1]) intValue]; i++){
                    if ([references objectForKey:[@(i) stringValue]]){
                     contents = [contents stringByAppendingString:[references objectForKey:[@(i) stringValue]]];
                        contents = [contents stringByAppendingString:@"\n\n"];
                    }
                    
                }
            }else {
                
            
                NSRange range = [num rangeOfString:@" "];
                if (range.location != NSNotFound){
                    // if it contains a space remove it
                    NSString *num2 = [num substringFromIndex:range.location + 1];
                    if ([references objectForKey:num2]){
                    contents = [contents stringByAppendingString:[references objectForKey:num2]];
                        contents = [contents stringByAppendingString:@"\n\n"];
                    }
                } else {
                    if ([references objectForKey:num]){
                    contents = [contents stringByAppendingString:[references objectForKey:num]];
                        contents = [contents stringByAppendingString:@"\n\n"];
                    }
                }
            }
        }
        }
        // create a text annotation next to the location where the reference number e.g [3] was found
       PTText *txt = [PTText Create:[doc GetSDFDoc]
        pos:[[PTPDFRect alloc] initWithX1:[location GetX1] + 5 y1:[location GetY1] x2:[location GetX2] + 5 y2:[location GetY2]]];
        PTPage *page = [doc GetPage:pageNum];
        [txt SetContents:contents];
        [txt SetColor:[[PTColorPt alloc] initWithX:0 y:1 z:0 w:0] numcomp:3];
        [txt SetPadding: 5];
        [page AnnotPushBack:txt];
    }
    
    
}

// checks if query is >= min and <=max
bool isWithinRange(double query, double min, double max){
    return (query >= min && query <= max);
}

// normalizes the element to 500x 500, extracts the xaxis values and label, yaxis values and label if available and adds
// a graph description to the textOnPage dictionary if the element was classified as a line/bar graph
static void GetGraphFeatures(PTElementReader *reader, PTElement *element ,int figurePageNum, PTPDFDoc *doc){
    
  
    NSMutableArray *textElem = [[NSMutableArray alloc] init];
    NSMutableArray *rectForTextElem =[[NSMutableArray alloc] init];
    

    NSMutableArray *xAxisValues = [[NSMutableArray alloc] init];
    NSMutableArray *yAxisValues = [[NSMutableArray alloc] init];
      

    bool startXaxis = false;
    bool startYaxis = false;
    bool endOfXaxis = false;
    bool endOfYaxis = false;
    long XaxisBorder = 0;
    long YaxisBorder = 0;
    bool XaxisPresent = false;
    bool YaxisPresent = false;
    bool YaxisTitlePresent = false;
  
    PTPDFRect *prevRect = [[PTPDFRect alloc] init];
    NSString *prevText;
    NSString *textForReader;
    NSString *xAxisLabel = @"";
    NSString *yAxisLabel = @"";
    NSString *otherinfo = @"";
    
    PTPDFRect *rectXObject = [element GetBBox];
    float xNorm = 500 / ( [rectXObject GetX2] - [rectXObject GetX1]);
    float yNorm = 500 / ([rectXObject GetY2] - [rectXObject GetY1]);
    
    [reader FormBegin];
    // get all text element and hold them in an array
    while ((element = [reader Next]) != NULL) {
        int type = [element GetType];
        if (type == e_pttext_obj){
            
            NSString *text = [element GetTextString];
            PTPDFRect *rect = [element GetBBox];
             
            // normalize coord
            [rect SetX1: ([rect GetX1] * xNorm)];
            [rect SetX2: ([rect GetX2] * xNorm)];
            [rect SetY1: ([rect GetY1] * yNorm)];
            [rect SetY2: ([rect GetY2] * yNorm)];
        
            
            if ([rectForTextElem count] == 0){
                [textElem addObject:text];
                [rectForTextElem addObject:rect];
                continue;
            }
            
            // get prev bbox
                prevRect = rectForTextElem[[rectForTextElem count] -1];
                prevText = textElem[[rectForTextElem count] -1];
                
        // check if the consecutive text elements should be one word
            if (isWithinRange([rect GetX1], [prevRect GetX2] - 0.15*xNorm, [prevRect GetX2] + 0.15*xNorm) && ([rect GetX2] != [prevRect GetX2])){
                        prevText = [prevText stringByAppendingString:text];
                        [textElem removeLastObject];
                        [textElem addObject:prevText];
                       [rectForTextElem removeLastObject];
                       
                       PTPDFRect *newRect = [[PTPDFRect alloc] init];
                       [newRect SetX1: fmin([prevRect GetX1], [rect GetX1])];
                        [newRect SetX2: fmax([prevRect GetX2],[rect GetX2])];
                        [newRect SetY1: fmin([prevRect GetY1],[rect GetY1])];
                        [newRect SetY2: fmax([prevRect GetY2], [rect GetY2])];
                       [rectForTextElem addObject:newRect];
                       
           
                   }else if ((([rect GetY1]- [prevRect GetY2]) <= 0.15*yNorm) && (([rect GetY1]- [prevRect GetY2]) >= 0)) {
                        prevText = [prevText stringByAppendingString:text];
                        [textElem removeLastObject];
                        [textElem addObject:prevText];
                       [rectForTextElem removeLastObject];

                       PTPDFRect *newRect = [[PTPDFRect alloc] init];
                        [newRect SetX1: fmin([prevRect GetX1],[rect GetX1])];
                         [newRect SetX2: fmax([prevRect GetX2],[rect GetX2])];
                         [newRect SetY1: fmin([prevRect GetY1],[rect GetY1])];
                         [newRect SetY2: fmax([prevRect GetY2],[rect GetY2])];
                        [rectForTextElem addObject:newRect];
                                            
                   } else {
                       [textElem addObject:text];
                       [rectForTextElem addObject:rect];
                   }
        
        }
    }
     [reader End];
    

  
    if ([textElem count] == 0) return;
    
    prevText = textElem[0];
    prevRect = rectForTextElem[0];
    for (int i = 1; i < [textElem count]; i++){
        NSString *text = textElem[i];
        PTPDFRect *rect =  rectForTextElem[i];
        NSString *prevText = textElem[i - 1];
        PTPDFRect *prevRect =  rectForTextElem[i - 1];
        
            // check if the last two elements were on the x-axis
            if (isWithinRange([rect GetY1], [prevRect GetY1] - yNorm, [prevRect GetY1] +yNorm ) && isWithinRange([rect GetY2], [prevRect GetY2] - yNorm, [prevRect GetY2] +yNorm )
                &&[prevRect GetX1] <= [rect GetX1] && [prevRect GetX2] <= [rect GetX2] && !endOfXaxis){
                if (!startXaxis){
                    [xAxisValues addObject:prevText];
                    startXaxis = true;
                    XaxisBorder = [rect GetY1];
                }
                
                [xAxisValues addObject:text];
                continue;
            } else if(startXaxis && (!isWithinRange([rect GetY1], ([prevRect GetY1] - yNorm), ([prevRect GetY1] +2*yNorm)) || !isWithinRange([rect GetY2], ([prevRect GetY2] - yNorm), ([prevRect GetY2] +2*yNorm)))){
                endOfXaxis = true;
                XaxisPresent = true;
            }
                
            // check if the last two elements were on the y-axis
        if (isWithinRange([rect GetX1],([prevRect GetX1] -7*xNorm),([prevRect GetX1] +7*xNorm))  && isWithinRange([rect GetX2],([prevRect GetX2] -7*xNorm),([prevRect GetX2] +7*xNorm)) && [prevRect GetY1] <= [rect GetY1] && [prevRect GetY2] <= [prevRect GetY2] && !endOfYaxis){
                if (!startYaxis){
                    [yAxisValues addObject:prevText];
                    startYaxis = true;
                    YaxisBorder = [rect GetX1];
                }
                [yAxisValues addObject:text];
                continue;
        }else if(startYaxis && (!isWithinRange([rect GetX1],([prevRect GetX1] -7*xNorm),([prevRect GetX1] +7*xNorm)) || !isWithinRange([rect GetX2],([prevRect GetX2] -7*xNorm),([prevRect GetX2] +7*xNorm)))){
      
                endOfYaxis = true;
                YaxisPresent = true;
            }
                
                if (startXaxis && ([rect GetY2] <= (XaxisBorder + yNorm))){
                    xAxisLabel = [xAxisLabel stringByAppendingString: text];
                } else if (startYaxis && ([rect GetX2] <= (YaxisBorder +yNorm))){
                    yAxisLabel = [yAxisLabel stringByAppendingString:text];
                    YaxisTitlePresent = true;
                } else {
                    otherinfo = [otherinfo stringByAppendingString:text];
                    otherinfo = [otherinfo stringByAppendingString:@" "];
                }
                
                
       
            }
 

    
    if(XaxisPresent && YaxisPresent && YaxisTitlePresent){
  
    // check if x axis is numerical or categorical
    if (isdigit ([xAxisValues[0] characterAtIndex:0])){
        // this is a line graph
        double dataxA = [xAxisValues[[xAxisValues count]-1] doubleValue];
        double dataxB =[xAxisValues[[xAxisValues count]-2] doubleValue];
        
        double incrementX = dataxA-dataxB;
        
        double datayA = [yAxisValues[[yAxisValues count]-1] doubleValue];
        double datayB =[yAxisValues[[yAxisValues count]-2] doubleValue];
        
        double incrementY = datayA-datayB;
        
        textForReader = [NSString stringWithFormat:@"Line graph. The x axis shows %@ with values between %@ and %@ in increments of %f. The y axis shows %@ with values between %@ and %@ in increments of %f. Other information found on the graph includes %@", xAxisLabel, xAxisValues[0], xAxisValues[[xAxisValues count] -1], incrementX, yAxisLabel, yAxisValues[0], yAxisValues[[yAxisValues count] -1],incrementY, otherinfo];
         
        
    } else {
        // figure is a bar graph
        NSString *xCategories = @"";
        for (id i in xAxisValues) {
               xCategories = [xCategories stringByAppendingString:i] ;
            xCategories = [xCategories stringByAppendingString:@" "];
           }
       
        double datayA = [yAxisValues[[yAxisValues count]-1] doubleValue];
        double datayB =[yAxisValues[[yAxisValues count]-2] doubleValue];
        
        double incrementY = datayA-datayB;
        
        textForReader = [NSString stringWithFormat:@"Bar Graph. The x axis shows %@ with categories %@. The y axis shows %@ with values between %@ and %@ in increments of %f. Other information found on the graph includes %@", xAxisLabel, xCategories, yAxisLabel, yAxisValues[0], yAxisValues[[yAxisValues count] -1], incrementY, otherinfo ];
       
    }
       
       
        [textOnPage setValue: textForReader forKey: [@(figurePageNum) stringValue]];
    
    }
}


//Takes in element reader, writer, doc and page number. Transforms the applicable element types, add bookmarks and hyperlinks
static void ProcessElements(PTElementReader *reader, PTElementWriter *writer, PTElementWriter *writerFirstPage, PTPDFDoc *doc, int pageNumber)
{
    int count = 1;
    PTElement *element;
    NSString *text;
    PTPDFRect * location;
    bool possibleRef = false;

   
    
     [reader ReaderBeginWithPage: [doc GetPage:pageNumber] ocg_context: 0];
    
    while ((element = [reader Next]))     // Read page contents
    {
        PTPage *newPage;
        switch ([element GetType])
        {
        case e_ptimage:
               
                TransformElement(element, newPage,  doc);
                AddBookmarks(pageNumber, numberOfPages,totalElemCount + numberOfPages, doc);
                AddHyperlinkToFigure(element,pageNumber,totalElemCount + numberOfPages, doc);
                AddHyperlinkBack(pageNumber, totalElemCount + numberOfPages, doc);
                count++;
                totalElemCount++;
                break;
          
       case e_pte_shading:
              
                TransformElement(element, newPage, doc);
                AddBookmarks(pageNumber,  numberOfPages,totalElemCount + numberOfPages, doc);
                AddHyperlinkToFigure(element,pageNumber,totalElemCount + numberOfPages, doc);
                AddHyperlinkBack(pageNumber, totalElemCount + numberOfPages, doc);
                count++;
                totalElemCount++;
                break;
                
        case e_ptform:
             
             
                TransformElement(element, newPage,  doc);
                GetGraphFeatures(reader, element,totalElemCount + numberOfPages, doc);
                AddBookmarks(pageNumber,  numberOfPages,totalElemCount + numberOfPages, doc);
                AddHyperlinkToFigure(element,pageNumber,totalElemCount + numberOfPages, doc);
                AddHyperlinkBack(pageNumber, totalElemCount + numberOfPages, doc);
                count++;
                totalElemCount++;
                break;
    
        case e_ptinline_image:
              
                TransformElement(element, newPage, doc);
                AddBookmarks(pageNumber, numberOfPages,totalElemCount + numberOfPages, doc);
                AddHyperlinkToFigure(element,pageNumber,totalElemCount + numberOfPages, doc);
                AddHyperlinkBack(pageNumber, totalElemCount + numberOfPages, doc);
                count++;
                totalElemCount++;

                break;
                
       
        case e_pttext_obj:
               
               
                if ([references count] != 0) {
                // if text contains a complete reference number e.g. [2]
                if ([ [element GetTextString] containsString:@"["] && [ [element GetTextString] containsString: @"]"]){
                    location = [element GetBBox];
                   addReferencePopUp( [element GetTextString], location, doc, pageNumber);
                } else if ([[element GetTextString] containsString:@"["] && ![ [element GetTextString] containsString: @"]"]){
                    possibleRef = true;
                    text = [element GetTextString];
                } else if (possibleRef){
                    text = [text stringByAppendingString:[element GetTextString]];
                    if ([text containsString:@"]"]){
                        possibleRef = false;
                        location = [element GetBBox];
                        addReferencePopUp(text, location, doc, pageNumber);
                    }
                    
                }
                    
                }
                 [writer WriteElement: element];
                break;
                
        default:
                [writer WriteElement: element];
        }
    
      
    }

   
}

// gets the child bookmarks of currBookmark and adds section and subsection numbering to the title if necessary
    static void getChildBookmarks(PTPDFDoc *doc, PTBookmark *currBookmark, int section){
        //getNext, gets the right sibling
        int subSection = 1;
        for (PTBookmark *item = [currBookmark GetFirstChild]; [item IsValid]; item=[item GetNext])
        {
            
            // get the destination page of each bookmark
            PTAction *action = [item GetAction];
            if ([action IsValid]) {
                if ([action GetType] == e_ptGoTo) {
                    PTDestination *dest = [action GetDest];
                    if ([dest IsValid]) {

                        NSString *title = [item GetTitle];
                        char firstChar = [title characterAtIndex:0];
                        if (!isdigit(firstChar)){
                            NSString *newTitle = [NSString stringWithFormat: @"%@.%@. %@",
                            @(section - 1),@(subSection), title];
                            [item SetTitle:newTitle];
                        }
                        subSection++;
                    }
                }
            }
            
        }
          
    }

// takes in a reference e.g. [1] and its location in the page's string and adds the reference title(s) to
// the dictionary corresponding to this page with the key being the location and value the reference title(s)
static void addReferenceLocation(NSString *ref, NSUInteger location, int pageNum){
    
  
       // extract the numbers
       // remove opening bracket
       NSRange range = [ref rangeOfString:@"["];
       NSInteger openingBracketIndex = range.location;
        ref = [ref substringFromIndex:openingBracketIndex + 1];
       // remove closing bracket and any other char after it
       range = [ref rangeOfString:@"]"];
       NSInteger closingBracketIndex = range.location;
       ref = [ref substringToIndex:closingBracketIndex];
       NSString *pageAndLocation = [NSString stringWithFormat: @"%@.%@", @(pageNum), @(location)];
    
  
       // if ref has only 2 characters or less, then ref contains only one reference number
       if ([ref length] <= 2){
           [pageLocationsToRef setValue: [references objectForKey:ref] forKey:pageAndLocation];
         
       } else{
           // this is the case where ref is [3,5,7,8-12] or [8-12] or [3, 4, 6]
           // get the numbers seperated by a comma
           NSArray *numbers = [ref componentsSeparatedByCharactersInSet:
           [NSCharacterSet characterSetWithCharactersInString:@","]];
           NSString *contents = @"";
           
           // if no numbers extracted, check if it is a range e.g. 15-20
           if ([numbers count] == 0){
               numbers = [ref componentsSeparatedByCharactersInSet:
               [NSCharacterSet characterSetWithCharactersInString:@"\u201320"]]; // Unicode key for "-"

               // if a range is extracted, add the references to the contents string
               for (int i = (int)numbers[0]; i <= (int)numbers[1]; i++){
                    contents = [contents stringByAppendingString:[references objectForKey:[@(i) stringValue]]];
                   contents = [contents stringByAppendingString:@"\n\n"];
               }
               
               
           }else {
           for (id num in numbers) {

               // check if one of the num is a range e.g. 15-20
               
               // check if a dash is represented by unicode \u201320
               NSRange range = [num rangeOfString:@"\u201320"];
               if (range.location != NSNotFound){
                   // contains a range of numbers
                   NSLog(@"contains -");
                   NSArray *numRange = [num componentsSeparatedByCharactersInSet:
                   [NSCharacterSet characterSetWithCharactersInString:@"\u201320"]];

                   for (int i = (int)numRange[0]; i < (int)numRange[1]; i++){
                        contents = [contents stringByAppendingString:[references objectForKey:[@(i) stringValue]]];
                        contents = [contents stringByAppendingString:@"\n\n"];
                   }
                   
               } else {
                   
               
                   NSRange range = [num rangeOfString:@" "];
                   if (range.location != NSNotFound){
                       // if it contains a space remove it
                       NSString *num2 = [num substringFromIndex:range.location + 1];
                       if ([references objectForKey:num2]){
                       contents = [contents stringByAppendingString:[references objectForKey:num2]];
                            contents = [contents stringByAppendingString:@"\n\n"];
                           
                       }
                   } else {
                       if ([references objectForKey:num]){
                       contents = [contents stringByAppendingString:[references objectForKey:num]];
                            contents = [contents stringByAppendingString:@"\n\n"];
                       }
                   }
               }
           }
           }
          
               [pageLocationsToRef setValue:contents forKey:pageAndLocation];
             
       }
       
    
}

// Takes in page in the document and returns the text contained in the page as a NSString
NSString *GetTextOnPage(PTPage *page,PTPDFDoc *doc){
    PTElement *element;
    NSString *fullText = @"";
    PTElementReader *reader = [[PTElementReader alloc] init];
    [reader ReaderBeginWithPage: page ocg_context: 0];
    int pageNum = [page GetIndex];
    double prevX2 = 0;
    double currX1 = 0;
    int count = 0;
    bool possibleRef = false;
    NSString *ref = @"";
    NSMutableArray *locations = [[NSMutableArray alloc] init];
    
    while ((element = [reader Next]))     // Read page contents
    {

            if([element GetType] == e_pttext_obj)
        {
            NSString *text = [element GetTextString];
            PTPDFRect *rect = [element GetBBox];
            
            // check if it contains a reference
            if (count == 0){
                prevX2 = [rect GetX2];
            }
            currX1 = [rect GetX1];
            if (currX1 - prevX2 > 1.7){
                // add a space
                fullText = [fullText stringByAppendingString:@" "];
            }
            
            // if text contains a complete reference number e.g. [2]
                    if ([text containsString:@"["] && [text containsString: @"]"]){
                        
                        // check if ref contains letters then it is not a reference. This could happen if there is a list or an array mentioned in the text e.g. [X1, X2, ... XN]
                        NSRange match = [text rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]];
                        if (match.location == NSNotFound){
                         
                        addReferenceLocation(text, [fullText length], pageNum);
                        [locations addObject:@([fullText length])];
                        }
                        
                    } else if ([text containsString:@"["] && ![text containsString: @"]"]){
                        possibleRef = true;
                        ref = [NSString stringWithString:text];
                    } else if (possibleRef){
                        ref = [ref stringByAppendingString:text];
                        if ([ref containsString:@"]"]){
                            possibleRef = false;
                            // check if ref contains letters then it is not a reference. This could happen if there is a list or an array mentioned in the text e.g. [X1, X2, ... XN]
                            NSRange match = [ref rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]];
                            if (match.location == NSNotFound){
                                
                            addReferenceLocation(ref, [fullText length], pageNum);
                            [locations addObject:@([fullText length])];
                            }
                        }
                        
                    }
                    
            
            fullText = [fullText stringByAppendingString:text];
            count = 1;
            prevX2 = [rect GetX2];
                  
        }
    }
    
    [pageToRefLocations setValue:locations forKey:[@(pageNum) stringValue]];
    [reader End];
    return fullText;
}

// takes in a doc and pageNum where the references section started and processes the text
// on the page to extract the references and adds them to a dictionary
static void getReferences(PTPDFDoc *doc, int pageNum){
    
    // start a reader and page iterator to go through the pages of the document from page number
    // pageNum until the end of the document
   
     PTPageIterator *itr = [doc GetPageIterator: pageNum];
    NSString *text = @"";
    
    // the references could span over multiple pages
    for (int i = pageNum; i <= numberOfPages; i++)
        {
            PTPage *page = [itr Current];
            text = [text stringByAppendingString:GetTextOnPage(page, doc)];
            [itr Next];
        }

    // find where the references start on the page
    NSString *refTitle = @"References";
    NSRange range = [text rangeOfString:refTitle options: 1];
    if (range.location != NSNotFound){
    text = [text substringFromIndex:range.location];

  
    NSString *prevRef = @"[1]";
    // find the references and add them to a dictionary
    for (int i = 1; ; i++){
        // create the reference number e.g. [1], [2], etc
       NSString *ref = [NSString stringWithFormat:@"[%d]", i];
        // find it in the text
        NSRange range = [text rangeOfString:ref];
        NSString *refTitle;
        NSInteger nextIndex = range.location;
        if (nextIndex == NSNotFound) {
             [references setValue:text forKey:[@(i - 1) stringValue]]; // this is the last reference
            break;
        } else {
       
            if(i != 1){
            // if it is found return the substring
            refTitle = [text substringToIndex:nextIndex];
            [references setValue:refTitle forKey:[@(i - 1) stringValue] ];
            prevRef = [ref copy];
            }
             text = [text substringFromIndex: nextIndex];
        }
    
    }
    }

}

// goes through the bookmark tree and adds every bookmark to a dictionary the key being the page number and the value being the bookmark. Adds section numbering to the bookmark titles if necessary
    static void getBookmarks (PTPDFDoc *doc, PTBookmark *currBookmark){
        int section = 1;
        //getNext, gets the right sibling
        for (PTBookmark *item = currBookmark; [item IsValid]; item=[item GetNext])
        {
            
            // get the destination page of each bookmark
            PTAction *action = [item GetAction];
            if ([action IsValid]) {
                if ([action GetType] == e_ptGoTo) {
                    PTDestination *dest = [action GetDest];
                    if ([dest IsValid]) {
                        
                        PTPage *page = [dest GetPage];
                        int pageNum = [page GetIndex];
                        NSString *title = [item GetTitle];
                        // if this is the references bookmark, call getReferences
                        if ([title rangeOfString:@"Reference"].location != NSNotFound) {
                            
                            getReferences(doc, pageNum);
                        }
                        
                        // if the bookmark title is not numbered, add numbering
                        char firstChar = [title characterAtIndex:0];
                        if (!isdigit(firstChar)){
                            NSString *newTitle = [NSString stringWithFormat: @"%@. %@", @(section), title];
                            [item SetTitle:newTitle];
                        }
                        if (![title containsString:@"References"]){
                        [lastSectionBookmarksOnPage setValue:item forKey:[@(pageNum) stringValue]];
                        }
                        section++;
                    }
                }
            }
             if ([item HasChildren]) getChildBookmarks(doc, item, section);
        }
          
    }

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


- (void)speechRecognizer:(SFSpeechRecognizer *)speechRecognizer availabilityDidChange:(BOOL)available {
    NSLog(@"Availability:%d",available);
    
}

- (void) restartAudioEngine{
  
        NSLog(@"restarting");
        if (audioEngine.isRunning) {
            [audioEngine stop];
           [recognitionRequest endAudio];
    }
          
        [self startListening];
}

- (void) restartAudioEngine:(NSTimer*)timer{
  
        NSLog(@"restarting in timer");
        if (audioEngine.isRunning) {
            [audioEngine stop];
           [recognitionRequest endAudio];
        }
        
        [self startListening];
       
}

// initializes speech recognizer, creates a recognition request, transcribes the user input and handles the result
- (void)startListening {
    
  
    
    // Initialize the AVAudioEngine
    audioEngine = [[AVAudioEngine alloc] init];
    
    // Make sure there's not a recognition task already running
    if (recognitionTask) {
        [recognitionTask cancel];
        recognitionTask = nil;
    }
    
    // Starts an AVAudio Session
    NSError *error;
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
    [audioSession setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error];
    
    // Starts a recognition process, in the block it logs the input or stops the audio
    // process if there's an error.
    recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    inputNode = audioEngine.inputNode;
    recognitionRequest.shouldReportPartialResults = YES;
    
   
    
    recognitionTask = [speechRecognizer recognitionTaskWithRequest:recognitionRequest resultHandler:^(SFSpeechRecognitionResult * _Nullable result, NSError * _Nullable error) {
        
        if (result) {
            // Whatever you say in the mic should be being logged
            // in the console.
            totalCommands = result.bestTranscription.formattedString;
            __block NSString *lastCommand = nil;
            
            NSLog(@"RESULT:%@",totalCommands);
           
           if ([totalCommands localizedCaseInsensitiveContainsString:@"read section "]){
               
              
               
               dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                   //Here is non-main thread.
                   // wait 3 seconds to check if user is done talking
                   NSString* preCommands = totalCommands;
                   [NSThread sleepForTimeInterval:3.0f];
                   
                   dispatch_async(dispatch_get_main_queue(), ^{
                       //returns to main thread.
                       // checks if user gave new commands since issuing the thread
                       if ([preCommands isEqualToString:totalCommands]){
                                     NSRange range = [totalCommands rangeOfString:@"read section " options: 1]; // case insensitive search
                                     NSUInteger location = range.location; // gets its index in the total commands
                                     location = location + [@"read section" length]+ 1; // gets the index of the section title asked for
                                     NSString *sectiontitle = [totalCommands substringFromIndex:location]; // gets the section title
                                     currentViewPage = self.pdfViewCtrl.GetCurrentPage;
                                     NSString *text = [textOnPage valueForKey: [@(currentViewPage) stringValue]];
                                  
                                     NSRange range2 = [text rangeOfString:sectiontitle options:1];
                                     textOffset = range2.location;
                                      if (textOffset == NSNotFound){
                                          NSString *msg = [NSString stringWithFormat:@"Could not find %@. Try again.", sectiontitle];
                                          AVSpeechUtterance *utterance = [[AVSpeechUtterance alloc] initWithString:msg];
                                          [synthesizer speakUtterance:utterance];
                                          [self restartAudioEngine];
                                          
                                      } else{
                                          
                                     NSString *textFromSection = [text substringFromIndex:range2.location];
                                     AVSpeechUtterance *utterance = [[AVSpeechUtterance alloc] initWithString:textFromSection];
                                     utterance.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];

                                     
                                     if ([synthesizer isSpeaking]){
                                          [synthesizer stopSpeakingAtBoundary: AVSpeechBoundaryImmediate];
                                     }
                                          [synthesizer speakUtterance:utterance];
                                           [self restartAudioEngine];
                                      }
                       }
                   });
               });
                 
              
           } else {

            // get last command
            [totalCommands enumerateSubstringsInRange:NSMakeRange(0, [totalCommands length]) options:NSStringEnumerationByWords | NSStringEnumerationReverse usingBlock:^(NSString *substring, NSRange subrange, NSRange enclosingRange, BOOL *stop) {
                lastCommand = substring;
                *stop = YES;
            }];
            
            
            if ([lastCommand isEqualToString: @"Start"] || [lastCommand isEqualToString: @"start"]){
                currentViewPage = self.pdfViewCtrl.GetCurrentPage;
                NSString *text = [textOnPage valueForKey: [@(currentViewPage) stringValue]];
                AVSpeechUtterance *utterance = [[AVSpeechUtterance alloc] initWithString:text];
                utterance.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];

                // to avoid starting twice
                if (![synthesizer isSpeaking] || [synthesizer isPaused]){
                    textOffset = 0;
                    [synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
                    [synthesizer speakUtterance:utterance];
                }
            }
            else if ([lastCommand isEqualToString: @"Pause"] || [lastCommand isEqualToString: @"pause"]){
                [synthesizer pauseSpeakingAtBoundary:AVSpeechBoundaryImmediate];
            }
            else if ([lastCommand isEqualToString: @"Resume"] || [lastCommand isEqualToString: @"resume"]){
                if ([synthesizerReferences isSpeaking]){
                    [synthesizerReferences stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
                }
                
               
                [synthesizer continueSpeaking];
                
            } else if ([lastCommand isEqualToString: @"Stop"] || [lastCommand isEqualToString: @"stop"]){
                [synthesizer stopSpeakingAtBoundary: AVSpeechBoundaryImmediate];
            } else if ([lastCommand isEqualToString: @"references"] || [lastCommand isEqualToString: @"references"]){
                
                requestedReferenceReading = true;
               
            }
        }
       if (error) {
            [self->audioEngine stop];
            [inputNode removeTapOnBus:0];
            self->recognitionRequest = nil;
            self->recognitionTask = nil;
        }
        }
    }
    ];
    // Sets the recording format
       AVAudioFormat *recordingFormat = [inputNode outputFormatForBus:0];
         // [inputNode removeTapOnBus:0];
       [inputNode installTapOnBus:0 bufferSize:1024 format:recordingFormat block:^(AVAudioPCMBuffer * _Nonnull buffer, AVAudioTime * _Nonnull when) {
           [self->recognitionRequest appendAudioPCMBuffer:buffer];
       }];
       
       // Starts the audio engine, i.e. it starts listening.
       [audioEngine prepare];
       [audioEngine startAndReturnError:&error];
       NSLog(@"Say Something, I'm listening");
    
   
}

// checks which range the speech synthesizer is at. if the user requested a reference, then retreive the last reference mentioned and
// give it as an utterence to the speech synthesizer
- (void) speechSynthesizer:(AVSpeechSynthesizer *)synthesizer willSpeakRangeOfSpeechString:(NSRange)characterRange utterance:(AVSpeechUtterance *)utterance{
    if (requestedReferenceReading){
        NSString *before = @"";
        before = [utterance.speechString substringToIndex:characterRange.location];
        NSString *after = @"";
        after = [utterance.speechString substringFromIndex:characterRange.location];
       
        
        requestedReferenceReading = false;
        [synthesizer pauseSpeakingAtBoundary:AVSpeechBoundaryImmediate];
         currentViewPage = self.pdfViewCtrl.GetCurrentPage;

        NSUInteger currentLocation = characterRange.location + textOffset;
        NSArray *allLocationsOnPage = [[NSArray alloc]initWithArray: [pageToRefLocations valueForKey: [@(currentViewPage)stringValue]] copyItems: YES];
        NSUInteger closestLocation = 0;
        
        // get the largest location number that is less than currentLocation
        for (id objLocation in allLocationsOnPage) {
            if([objLocation integerValue] <= currentLocation){
                closestLocation = [objLocation integerValue];
            } else {
                break;
            }
        }
        
        if(closestLocation == 0){
            AVSpeechUtterance *utterance = [[AVSpeechUtterance alloc] initWithString:@"No References to Read"];
            [synthesizerErrors speakUtterance:utterance];
            [self restartAudioEngine];
      
            
        } else{
        
         NSString *pageAndLocation = [NSString stringWithFormat: @"%@.%@", @(currentViewPage), @(closestLocation)];
        
        NSString *references = [pageLocationsToRef objectForKey:pageAndLocation];
            NSLog(@"%@", references);
            AVSpeechUtterance *utterance = [[AVSpeechUtterance alloc] initWithString:references];
                    utterance.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
           [self InformativeAlertWithRef:references referencesUtterance:utterance];
           
        [synthesizerReferences speakUtterance:utterance];
        }
     
        
    }
   
}


- (void)viewDidAppear:(BOOL)animated {

    [super viewDidLoad];
    
}

- (BOOL)textFieldShouldReturn:(UITextField *)pdfURL
{
    return YES;
}
// pop up informative alert that shows the references
-(void) InformativeAlertWithRef: (NSString * ) msg referencesUtterance: (AVSpeechUtterance *) ref {
   
    // This will provide a heading "References" and display a text message: msg (references)
  UIAlertController * alertvc = [UIAlertController alertControllerWithTitle: @ "References" message: msg preferredStyle: UIAlertControllerStyleAlert];
    
    // UIAlertAction provides title and default style
  UIAlertAction * action = [UIAlertAction actionWithTitle: @ "Done" style: UIAlertActionStyleDefault handler: ^ (UIAlertAction * _Nonnull action) {
      [synthesizerReferences stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
                              NSLog(@ "Done Tapped");}];
    
    
    UIAlertAction * action2 = [UIAlertAction actionWithTitle: @ "Reread" style: UIAlertActionStyleDefault handler: ^ (UIAlertAction * _Nonnull action) {
        
        [synthesizerReferences stopSpeakingAtBoundary: AVSpeechBoundaryImmediate];
        [self InformativeAlertWithRef:msg referencesUtterance:ref];
        AVSpeechUtterance *utterance = [[AVSpeechUtterance alloc] initWithString: ref.speechString];
        utterance.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
        [synthesizerReferences speakUtterance:utterance];
       
        
    }];
    
    
   // connect the action and alert
   // connect an action controller to the current view controller using presentViewController.
  [alertvc addAction: action];
  [alertvc addAction: action2];
  [self presentViewController: alertvc animated: true completion: nil];
}

// informative alert when the user does not insert a proper url in the text field
-(void) InformativeAlertWithmsg: (NSString * ) msg {
   // NSLog (@"in msg");
    // This will provide a heading URL alert and display a text message msg.
  UIAlertController * alertvc = [UIAlertController alertControllerWithTitle: @ "URL Alert" message: msg preferredStyle: UIAlertControllerStyleAlert];
    
    // UIAlertAction provides title and default style
  UIAlertAction * action = [UIAlertAction actionWithTitle: @ "Okay" style: UIAlertActionStyleDefault handler: ^ (UIAlertAction * _Nonnull action) {
                              NSLog(@ "Okay Tapped");}];
   // connect the action and alert
   // connect an action controller to the current view controller using presentViewController.
  [alertvc addAction: action];
  [self presentViewController: alertvc animated: true completion: nil];
}


// runs when the user clicks on the continue button
// starts preprocessing and then views the documents
- (IBAction)continueButton2: (id) sender {
    
    pdfNSURL = [NSURL URLWithString:pdfURL.text];
    
    
     // Get the PDF Data from the url in a NSData Object
     NSData *pdfData = [[NSData alloc] initWithContentsOfURL:pdfNSURL];
    if (pdfData.length == 0){
         [self InformativeAlertWithmsg:@"PDF not valid. Please enter a valid URL."];
    } else {
     PTPDFDoc *doc =[[PTPDFDoc alloc] initWithBuf:pdfData buf_size:[pdfData length]];
             [doc InitSecurityHandler];
        
        // Initialize the Speech Recognizer with the locale
          speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US"]];
          
          // Set speech recognizer delegate
          speechRecognizer.delegate = self;
          
        
          // Request the authorization to make sure the user is asked for permission so you can
          // get an authorized response
          [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
              switch (status) {
                  case SFSpeechRecognizerAuthorizationStatusAuthorized:
                      NSLog(@"Authorized");
                      break;
                  case SFSpeechRecognizerAuthorizationStatusDenied:
                      NSLog(@"Denied");
                      break;
                  case SFSpeechRecognizerAuthorizationStatusNotDetermined:
                      NSLog(@"Not Determined");
                      break;
                  case SFSpeechRecognizerAuthorizationStatusRestricted:
                      NSLog(@"Restricted");
                      break;
                  default:
                      break;
              }
          }];
        
        // Create a PTDocumentViewController
        PTDocumentViewController *documentController = [[PTDocumentViewController alloc] init];
          
             pdfViewCtrl = documentController.pdfViewCtrl;

          
              PTElementWriter *writer = [[PTElementWriter alloc] init];
              PTElementWriter *writerFirstPage = [[PTElementWriter alloc] init];
              PTElementReader *reader = [[PTElementReader alloc] init];
              
              numberOfPages = doc.GetPageCount;
              PTPageIterator *itr = [doc GetPageIterator: 1];
              
              lastSectionBookmarksOnPage = [[NSMutableDictionary alloc] init];
              pageToRefLocations =  [NSMutableDictionary dictionary];
              pageLocationsToRef = [[NSMutableDictionary alloc] init];
              references = [[NSMutableDictionary alloc] init];
              textOnPage = [[NSMutableDictionary alloc] init];
              numFiguresPerSection = [[NSMutableDictionary alloc]init];
        
           PTBookmark *firstBookmark = [doc GetFirstBookmark];
         
          if ([firstBookmark IsValid]){
              NSString *title = [firstBookmark GetTitle];
              if([title isEqualToString:@"Abstract"]) firstBookmark = [firstBookmark GetNext];
           }
          getBookmarks (doc, firstBookmark);
          
          // if the document has no bookmarks, start looking from the last page to find the references section
          NSUInteger bookmarkNum = [lastSectionBookmarksOnPage count];
          if (bookmarkNum == 0){
              int refPage = numberOfPages - 1;
              while ([references count] == 0){
              getReferences(doc,refPage);
                  refPage--;
              }
          }
        
        
          totalElemCount = 1;
              for (int i = 0; i < numberOfPages; i++)
                     {
                      
                      
                         PTPage *page = [itr Current];

                         [reader ReaderBeginWithPage: page ocg_context: 0];
                         [writer WriterBeginWithPage: page placement: e_ptreplacement page_coord_sys: NO compress: YES resources: [page GetResourceDict] ];
                      
                        ProcessElements(reader, writer, writerFirstPage, doc, i + 1);
                        
                         
                         [writer End];
                         [reader End];
         
                        NSString *textForReader = GetTextOnPage(page, doc);
                         [textOnPage setValue: textForReader forKey: [@(i + 1) stringValue]];
           
                         [itr Next];
                     }
      
        
        navigationControllerDoc = [[UINavigationController alloc] initWithRootViewController:documentController];
        [documentController openDocumentWithPDFDoc:doc];
        [navigationControllerDoc willMoveToParentViewController:self];
        navigationControllerDoc.view.frame = self.view.frame;  //Set a frame or constraints
        [self.view addSubview:navigationControllerDoc.view];
        [self addChildViewController: navigationControllerDoc];
        [navigationControllerDoc didMoveToParentViewController:self];
        
    
        synthesizer= [[AVSpeechSynthesizer alloc] init];
        synthesizerReferences = [[AVSpeechSynthesizer alloc]init];
        synthesizerErrors = [[AVSpeechSynthesizer alloc]init];
        synthesizer.delegate =  self;
        
            [NSTimer scheduledTimerWithTimeInterval:58.0
                            target:self
                            selector:@selector(restartAudioEngine:)
                            userInfo:nil
                            repeats:YES];
     
        [self startListening];
    }
}


@end
